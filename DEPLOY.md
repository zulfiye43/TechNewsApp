# TechDigest täglich automatisch — Setup in 6 Schritten

## 1. GitHub-Repo erstellen
Auf github.com → New Repository → Name `TechDigest`, **Public** (nötig, damit
die App die Dateien ohne Login laden kann). Nichts initialisieren.

## 2. Projekt pushen
```bash
cd ~/Desktop/TechDigest
git init
git add .
git commit -m "TechDigest App + Pipeline"
git branch -M main
git remote add origin https://github.com/DEIN-NAME/TechDigest.git
git push -u origin main
```

## 3. API-Keys als Secrets hinterlegen
Im Repo: Settings → Secrets and variables → Actions → **New repository secret**:
- `ANTHROPIC_API_KEY` = dein Anthropic-Key
- `ELEVENLABS_API_KEY` = dein ElevenLabs-Key

Optional unter "Variables": `ELEVEN_MODEL` = `eleven_multilingual_v2`
(Standard ist das günstigere `eleven_flash_v2_5`).

## 4. Workflow testen
Tab **Actions** → "Täglicher Tech-Digest" → **Run workflow**. Nach ~2 Minuten
sollte ein Commit "Digest 2026-…" mit frischer `backend/out/digest.mp3` da sein.
Ab jetzt läuft das automatisch jeden Tag um 06:15.

## 5. App auf das Repo zeigen
In `TechDigest/Models.swift` die Zeile mit `remoteBase` ausfüllen:
```swift
static let remoteBase: URL? = URL(string:
    "https://raw.githubusercontent.com/DEIN-NAME/TechDigest/main/backend/out/")
```
Dann ⌘R. Die App lädt ab jetzt bei jedem Öffnen den aktuellen Digest und
streamt die heutige Podcast-Folge. Pull-to-Refresh holt Updates.

## 6. Fertig
Die gebündelte digest.json/mp3 in Xcode bleibt als Offline-Fallback —
falls kein Netz da ist, zeigt die App den letzten eingebauten Stand.

## Hinweise
- Push-Zeit ändern: Cron in `.github/workflows/daily-digest.yml` (UTC!).
- Kosten: Claude-API wenige Cent/Tag. ElevenLabs: Flash-Modell ~1.600
  Credits/Folge → Starter-Plan (5 $/Monat, 30.000 Credits) reicht für
  tägliche Folgen knapp nicht bei 4 Min — entweder Folgen ~3 Min halten
  oder Creator-Plan (22 $/Monat) für das beste Modell.
- GitHub Actions + Hosting: kostenlos (Public Repo).
