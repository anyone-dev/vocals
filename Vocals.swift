// Vocals : guette les vocaux WhatsApp (enregistrés ou reçus) et les fichiers audio
// posés dans Téléchargements / Bureau, les transcrit avec ElevenLabs (Scribe) et
// copie le texte dans le presse-papiers dès qu'il est prêt.
import SwiftUI
import AppKit
import CoreServices
import UserNotifications

// MARK: - Réglages

let audioExtensions: Set<String> = ["opus", "ogg", "oga", "m4a", "mp3", "wav", "aac", "caf", "mp4", "webm", "flac", "aiff"]

func watchedFolders() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [
        home.appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media"),
        home.appendingPathComponent("Library/Containers/net.whatsapp.WhatsApp/Data/Library/Application Support/WhatsApp"),
        home.appendingPathComponent("Library/Containers/desktop.WhatsApp/Data"),
        home.appendingPathComponent("Downloads"),
        home.appendingPathComponent("Desktop"),
    ].filter { FileManager.default.fileExists(atPath: $0.path) }
}

// MARK: - Modèle

struct Transcript: Identifiable, Codable, Equatable {
    var id = UUID()
    var fileName: String
    var date: Date
    var text: String
    var state: State
    var error: String?
    enum State: String, Codable { case pending, done, failed }
}

@MainActor
final class Store: ObservableObject {
    @Published var items: [Transcript] = []
    @Published var apiKey: String = {
        if let saved = UserDefaults.standard.string(forKey: "apiKey"), !saved.isEmpty { return saved }
        if !embeddedApiKey.isEmpty { UserDefaults.standard.set(embeddedApiKey, forKey: "apiKey") }
        return embeddedApiKey
    }() {
        didSet { UserDefaults.standard.set(apiKey, forKey: "apiKey") }
    }
    @Published var autoCopy: Bool = UserDefaults.standard.object(forKey: "autoCopy") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCopy, forKey: "autoCopy") }
    }
    @Published var lastCopiedId: UUID?
    @Published var folders: [URL] = []

    private var seen = Set<String>()
    private var stream: FSEventStreamRef?
    private let startedAt = Date()
    private let historyURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vocals", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("historique.json")
    }()

    init() {
        if let data = try? Data(contentsOf: historyURL),
           let saved = try? JSONDecoder().decode([Transcript].self, from: data) {
            items = saved.map { var t = $0; if t.state == .pending { t.state = .failed; t.error = "Interrompu" }; return t }
        }
        startWatching()
        Updater.shared.start()
    }

    func save() {
        if let data = try? JSONEncoder().encode(Array(items.prefix(200))) { try? data.write(to: historyURL) }
    }

    // FSEvents : réveil immédiat à chaque fichier créé ou modifié.
    func startWatching() {
        folders = watchedFolders()
        guard !folders.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let store = Unmanaged<Store>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            Task { @MainActor in list.prefix(count).forEach { store.consider(path: $0) } }
        }
        stream = FSEventStreamCreate(nil, callback, &ctx, folders.map(\.path) as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                     UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func consider(path: String) {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        guard audioExtensions.contains(ext), !url.lastPathComponent.hasPrefix("."), !seen.contains(path) else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let created = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date),
              created >= startedAt.addingTimeInterval(-5) else { return }
        seen.insert(path)
        Task { await waitStableThenTranscribe(url) }
    }

    func addManually(_ urls: [URL]) {
        for url in urls where audioExtensions.contains(url.pathExtension.lowercased()) {
            seen.insert(url.path)
            Task { await transcribe(url) }
        }
    }

    // Attend que le fichier ne grossisse plus (WhatsApp l'écrit en plusieurs fois).
    private func waitStableThenTranscribe(_ url: URL) async {
        var last: Int64 = -1
        for _ in 0..<40 {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            if size > 0 && size == last { break }
            last = size
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        await transcribe(url)
    }

    func transcribe(_ url: URL) async {
        var item = Transcript(fileName: url.lastPathComponent, date: Date(), text: "", state: .pending)
        items.insert(item, at: 0)
        do {
            let data = try Data(contentsOf: url)
            item.text = try await ElevenLabs.transcribe(data: data, fileName: url.lastPathComponent, key: apiKey)
            item.state = .done
            if item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { item.text = "(silence)" }
        } catch {
            item.state = .failed
            item.error = error.localizedDescription
        }
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item }
        save()
        if item.state == .done {
            if autoCopy { copy(item) }
            notify(item)
        }
    }

    func retry(_ item: Transcript) {
        items.removeAll { $0.id == item.id }
        save()
        if let url = findFile(named: item.fileName) { Task { await transcribe(url) } }
    }

    private func findFile(named name: String) -> URL? {
        for folder in folders {
            let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
            while let u = e?.nextObject() as? URL { if u.lastPathComponent == name { return u } }
        }
        return nil
    }

    func copy(_ item: Transcript) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        lastCopiedId = item.id
    }

    func delete(_ item: Transcript) { items.removeAll { $0.id == item.id }; save() }

    private func notify(_ item: Transcript) {
        NSSound(named: "Glass")?.play()
        let c = UNMutableNotificationContent()
        c.title = autoCopy ? "Vocal transcrit et copié" : "Vocal transcrit"
        c.body = String(item.text.prefix(180))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id.uuidString, content: c, trigger: nil))
    }
}

// MARK: - ElevenLabs

enum ElevenLabs {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    static func transcribe(data: Data, fileName: String, key: String) async throws -> String {
        guard !key.isEmpty else { throw Failure(message: "Clé ElevenLabs manquante (réglages)") }
        let boundary = "vocals-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model_id", "scribe_v2")
        field("tag_audio_events", "false")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (resp, http) = try await URLSession.shared.upload(for: req, from: body)
        let status = (http as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = String(data: resp, encoding: .utf8)?.prefix(200) ?? ""
            throw Failure(message: "ElevenLabs a répondu \(status) : \(detail)")
        }
        struct R: Decodable { let text: String }
        return try JSONDecoder().decode(R.self, from: resp).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Interface

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var showSettings = false
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.items.isEmpty { empty } else { list }
        }
        .frame(minWidth: 340, idealWidth: 400, minHeight: 360, idealHeight: 520)
        .overlay(dropping ? RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3).padding(4) : nil)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in store.addManually([url]) } }
                }
            }
            return true
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
        .onAppear { if store.apiKey.isEmpty { showSettings = true } }
    }

    var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform").font(.title2).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Vocals").font(.headline)
                Text(store.folders.isEmpty ? "Aucun dossier surveillé" : "À l'écoute de WhatsApp")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Copie auto", isOn: $store.autoCopy).toggleStyle(.switch).controlSize(.small).font(.caption)
            Button { showSettings = true } label: { Image(systemName: "gearshape") }.buttonStyle(.borderless)
        }
        .padding(12)
    }

    var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "mic.circle").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Enregistre un vocal sur WhatsApp").font(.headline)
            Text("Le texte apparaît ici et part dans le presse-papiers.\nTu peux aussi glisser un fichier audio dans cette fenêtre.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(store.items) { item in Row(item: item) }
            }
            .padding(12)
        }
    }
}

struct Row: View {
    @EnvironmentObject var store: Store
    let item: Transcript

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.date, style: .time).font(.caption).foregroundStyle(.secondary)
                Spacer()
                switch item.state {
                case .pending:
                    ProgressView().controlSize(.small)
                    Text("Transcription…").font(.caption).foregroundStyle(.secondary)
                case .done:
                    Button {
                        store.copy(item)
                    } label: {
                        Label(store.lastCopiedId == item.id ? "Copié" : "Copier",
                              systemImage: store.lastCopiedId == item.id ? "checkmark" : "doc.on.doc")
                            .frame(minWidth: 70)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(store.lastCopiedId == item.id ? .green : .accentColor)
                    .controlSize(.small)
                case .failed:
                    Button("Réessayer") { store.retry(item) }.controlSize(.small)
                }
                Menu {
                    Button("Supprimer", role: .destructive) { store.delete(item) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).frame(width: 22)
            }
            if item.state == .failed {
                Text(item.error ?? "Échec").font(.callout).foregroundStyle(.red)
            } else if item.state == .done {
                Text(item.text).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if item.state == .done { store.copy(item) } }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Réglages").font(.headline)
            Text("Clé ElevenLabs").font(.caption).foregroundStyle(.secondary)
            SecureField("sk_…", text: $store.apiKey).textFieldStyle(.roundedBorder)
            Text("Version \(Updater.currentVersion) · mises à jour automatiques").font(.caption).foregroundStyle(.secondary)
            Text("Dossiers surveillés").font(.caption).foregroundStyle(.secondary)
            ForEach(store.folders, id: \.self) { f in
                Text(f.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            }
            HStack { Spacer(); Button("OK") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 380)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct VocalsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup("Vocals") {
            ContentView().environmentObject(store)
        }
        .windowResizability(.contentSize)
        MenuBarExtra {
            if let last = store.items.first(where: { $0.state == .done }) {
                Button("Copier le dernier vocal") { store.copy(last) }
                Text(String(last.text.prefix(60)))
                Divider()
            }
            Button("Ouvrir Vocals") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.title == "Vocals" }?.makeKeyAndOrderFront(nil)
            }
            Button("Rechercher une mise à jour") { Task { await Updater.shared.check(manual: true) } }
            Text("Version \(Updater.currentVersion)")
            Button("Quitter") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "waveform")
        }
    }
}
