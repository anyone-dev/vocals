# Vocals

App Mac : guette les vocaux WhatsApp (et les audios posés dans Téléchargements / Bureau),
les transcrit avec ElevenLabs (Scribe v2) et copie le texte dans le presse-papiers.

- Mise à jour automatique : au lancement puis toutes les 2 h, depuis la dernière release de ce dépôt.
  Une version n'est installée que si sa signature correspond à celle de l'app en place.
- Signature stable « Anyone Vocals » (certificat gardé sur STARCOMMAND, `signature/`, hors dépôt) :
  macOS garde les autorisations d'une version à l'autre.
- Publier : `./release.sh <version>` sur STARCOMMAND.
