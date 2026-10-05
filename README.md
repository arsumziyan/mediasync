# MediaSync — Smart Multimedia Organizer with On-Device ML & Sync

An iOS client (SwiftUI + Core ML / Vision) backed by an async FastAPI service. Photos, video, audio and
notes are **analyzed and tagged on the device**, then **encrypted on the device** before upload, so the
server and object store never see raw media.

```
iOS (SwiftUI, SwiftData)                         FastAPI (async)            Postgres / Supabase
 ├─ Import → Vision / SoundAnalysis / NL  ──┐     ├─ /auth  (JWT + refresh)   └─ users, assets (rev cursor)
 ├─ Offline cache (SwiftData + files)       │     ├─ /assets (upsert, blob)
 ├─ AES-256-GCM encrypt (CryptoKit)         ├───▶ ├─ /sync/changes (delta)  ── S3 / MinIO: ciphertext only
 └─ SyncEngine: push → pull (BGTask)        ┘     └─ soft-delete tombstones
```

## What's where

| Path | What |
|---|---|
| `backend/` | FastAPI service, tests (`pytest`), Dockerfile |
| `docker-compose.yml` | Postgres + MinIO + API, one command |
| `ios/` | SwiftUI app sources + `project.yml` (XcodeGen) |

## Run the backend

```bash
# Full stack (Postgres + MinIO + API) on http://localhost:8000  (docs at /docs)
docker compose up --build

# or: lightweight local dev with SQLite + local disk, no Docker
cd backend && pip install -r requirements.txt
MEDIASYNC_STORAGE_BACKEND=local uvicorn app.main:app --reload

# tests (SQLite + local storage, no services needed)
cd backend && pytest
```

Supabase: set `MEDIASYNC_DATABASE_URL=postgresql+asyncpg://USER:PASS@HOST:5432/postgres` and point the
`MEDIASYNC_S3_*` variables at Supabase Storage's S3 endpoint (or any S3/MinIO). Set a real
`MEDIASYNC_JWT_SECRET` (`openssl rand -hex 32`).

## Run the iOS app

Requires Xcode 15+, iOS 17+ (SwiftData, Observation).

```bash
brew install xcodegen
cd ios && xcodegen          # creates MediaSync.xcodeproj from project.yml
open MediaSync.xcodeproj    # set your Team, then Run on a simulator or device
```

The login screen has an **API URL** field (default `http://localhost:8000`, which works from the
simulator). On a physical device use your computer's LAN IP or a deployed HTTPS URL.

Optional: add your own Create ML image classifier named `MediaClassifier.mlmodel` to the target;
`ImageAnalyzer` picks it up automatically and merges its top label with Apple's built-in taxonomy.

## Feature map

- **SwiftUI UI** — library grid, tag/kind/sentiment filter chips, full-text search (names, tags, OCR text),
  detail view with tag editing.
- **Custom media player** — own `AVPlayerLayer` + controls: scrubber, ±15 s skip, speed menu, haptics
  on every interaction, animated waveform for audio.
- **Offline-first** — everything is written locally first (`SwiftData` + protected files); sync happens
  when possible. Remote-only items are downloaded + decrypted on first open and then cached.
- **On-device ML** — `VNClassifyImageRequest` + optional custom Core ML model, `VNRecognizeTextRequest`
  OCR, `SNClassifySoundRequest` for audio, on-device `SFSpeechRecognizer` transcripts, and
  `NaturalLanguage` sentiment/keywords. OCR text and transcripts never leave the device.
- **Sync** — `SyncEngine` pushes pending changes (metadata → encrypted blob with SHA-256 check), then
  pulls `/sync/changes?since=<cursor>` (paginated, with deletion tombstones). Triggers: launch,
  foreground, pull-to-refresh, network regained, and `BGAppRefreshTask`.
- **Auth** — email/password → JWT access (30 min) + refresh (30 days) tokens in the Keychain; the client
  auto-refreshes once on 401.

## Design notes & known limits

- **What the server can see:** ciphertext, file size/hash, filename, kind, **tags and sentiment** (needed
  for cross-device filtering). If tags are sensitive, drop them from `AssetUpsertDTO` and re-derive on each device.
- **Encryption key:** generated on first use, stored in the Keychain with `kSecAttrSynchronizable` so
  iCloud Keychain shares it across your devices. Lose it and uploaded blobs are unrecoverable.
- **Whole-file encryption** (`AES.GCM.seal`) loads the file in memory — fine for photos/audio/short clips;
  switch to chunked sealing for large videos.
- **Uploads use a foreground `URLSession`.** For uploads that survive app suspension, move to a
  `URLSessionConfiguration.background` session.
- **Conflicts:** unpushed local edits win; otherwise the latest server revision wins (no field-level merge).
- **Refresh tokens are stateless** (no revocation list). Add a token table if you need server-side logout.
- **Not compiled here:** the backend is tested (6 passing tests); the Swift sources were written without
  access to Xcode, so expect to fix a few compile errors on first build.
