// Mise à jour automatique : au lancement puis toutes les 2 h, lit latest.json,
// télécharge la nouvelle version, vérifie qu'elle est signée par la même équipe
// Apple que l'app en place, la met à la place de l'ancienne et relance.
import AppKit
import Security

@MainActor
final class Updater {
    static let shared = Updater()
    static let feedURL = URL(string: ProcessInfo.processInfo.environment["VOCALS_FEED"]
        ?? "https://github.com/anyone-dev/vocals/releases/latest/download/latest.json")!
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0 }

    struct Feed: Decodable { let version: String; let build: Int; let url: URL }

    private var timer: Timer?
    private var busy = false

    func start() {
        Task { await check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 2 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check(manual: false) }
        }
    }

    func check(manual: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            var req = URLRequest(url: Self.feedURL, cachePolicy: .reloadIgnoringLocalCacheData)
            req.timeoutInterval = 30
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Fail("flux indisponible") }
            let feed = try JSONDecoder().decode(Feed.self, from: data)
            guard feed.build > Self.currentBuild else {
                if manual { alert("Vocals est à jour", "Version \(Self.currentVersion).") }
                return
            }
            try await install(feed)
        } catch {
            NSLog("Vocals mise à jour : %@", error.localizedDescription)
            if manual { alert("Mise à jour impossible", error.localizedDescription) }
        }
    }

    private func install(_ feed: Feed) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("vocals-maj-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let (zip, resp) = try await URLSession.shared.download(from: feed.url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Fail("téléchargement refusé") }
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let newApp = work.appendingPathComponent("Vocals.app")
        guard fm.fileExists(atPath: newApp.path) else { throw Fail("archive sans Vocals.app") }
        try verifySameTeam(newApp)

        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        let old = parent.appendingPathComponent(".Vocals-ancienne.app")
        try? fm.removeItem(at: old)
        try fm.moveItem(at: current, to: old)
        do {
            try fm.moveItem(at: newApp, to: current)
        } catch {
            try? fm.moveItem(at: old, to: current)
            throw error
        }
        try? fm.removeItem(at: old)
        try? fm.removeItem(at: work)

        // Relance la nouvelle version une fois celle-ci fermée.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", current.path]
        try p.run()
        NSApp.terminate(nil)
    }

    /// La nouvelle version doit satisfaire l'exigence de signature de l'app en place
    /// (même identifiant, même certificat) : sinon elle est refusée.
    private func verifySameTeam(_ url: URL) throws {
        var mine: SecStaticCode?, theirs: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(url as CFURL, [], &theirs) == errSecSuccess, let theirs else {
            throw Fail("signature illisible")
        }
        let status = SecStaticCodeCheckValidity(theirs, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement)
        guard status == errSecSuccess else { throw Fail("signature refusée (\(status))") }
    }

    static func teamIdentifier(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Fail("\(tool) a échoué") }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    struct Fail: LocalizedError { let message: String; init(_ m: String) { message = m }; var errorDescription: String? { message } }
}
