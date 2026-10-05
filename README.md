# MediaSync

**A privacy-first multimedia organizer for iOS.** Photos, videos, audio and notes are classified and tagged
**on the device** with Core ML / Vision, encrypted **on the device**, and then synced to an async FastAPI
backend. The server and object store only ever see ciphertext.

![Swift](https://img.shields.io/badge/Swift-5.9-orange?logo=swift)
![iOS](https://img.shields.io/badge/iOS-17%2B-blue?logo=apple)
![Python](https://img.shields.io/badge/Python-3.10%2B-3776AB?logo=python&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-async-009688?logo=fastapi&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-or%20SQLite-336791?logo=postgresql&logoColor=white)

> Resume-style summary: *Architected an iOS client in SwiftUI using Core ML and Vision for on-device media
> classification, backed by an async FastAPI service with JWT auth, delta sync and encrypted object storage.*

<!-- Add screenshots here, e.g. docs/library.png, docs/player.png -->

---

## Contents

- [Features](#features)
- [Architecture](#architecture)
- [Tech stack](#tech-stack)
- [Project structure](#project-structure)
- [Getting started](#getting-started)
  - [1. Backend (no Docker)](#1-backend-no-docker)
  - [2. Backend (Docker Compose)](#2-backend-docker-compose)
  - [3. iOS app](#3-ios-app)
- [Configuration](#configuration)
- [API reference](#api-reference)
- [How it works](#how-it-works)
- [Security & privacy model](#security--privacy-model)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [Roadmap](#roadmap)

---

## Features

**iOS client**
- SwiftUI library grid with filter chips (kind, sentiment, tag) and full-text search over filenames, tags and OCR text.
- Custom media player built on `AVPlayerLayer`: scrubber, ±15 s skip, playback speed, animated waveform for audio, haptic feedback on every interaction.
- Offline-first: everything is saved locally first and syncs when the server is reachable. Remote-only items are downloaded and decrypted on first open, then cached.
- Background sync on launch, foreground, pull-to-refresh, and via `BGAppRefreshTask`.
- Editable tags and a "re-run analysis" action.

**On-device ML (no network required)**

| Media | What runs | Output |
|---|---|---|
| Photo | `VNClassifyImageRequest`, optional custom Core ML model, `VNRecognizeTextRequest` (OCR) | scene/object tags, extracted text |
| Video | Key-frame image analysis + audio analysis | tags, transcript |
| Audio | `SNClassifySoundRequest` (SoundAnalysis), on-device `SFSpeechRecognizer` | sound tags, transcript |
| Text | `NaturalLanguage` (`NLTagger`) | keyword tags |
| Any text (OCR / transcript / note) | `NLTagger` sentiment score | `positive` / `neutral` / `negative` |

**Backend**
- JWT auth (access + refresh tokens), bcrypt password hashing.
- Idempotent asset upserts using client-generated UUIDs (safe to retry from flaky connections).
- Streaming uploads/downloads with SHA-256 integrity checks and a size cap.
- Cursor-based delta sync with deletion tombstones, per-user isolation.
- Pluggable blob storage: S3 / MinIO, or local disk for development.
- Async SQLAlchemy 2.0 on PostgreSQL (incl. Supabase) or SQLite.

## Architecture

```mermaid
flowchart LR
    subgraph iOS["iOS app (SwiftUI + SwiftData)"]
        UI[Library / Detail / Player]
        ML["On-device ML<br/>Vision · SoundAnalysis · NaturalLanguage · Core ML"]
        STORE[("Offline cache<br/>SwiftData + files")]
        CRYPTO["AES-256-GCM<br/>(CryptoKit)"]
        SYNC[SyncEngine]
        UI --> ML --> STORE
        STORE --> SYNC --> CRYPTO
    end

    subgraph API["FastAPI service"]
        AUTH["/auth"]
        ASSETS["/assets"]
        DELTA["/sync/changes"]
    end

    PG[("PostgreSQL / Supabase<br/>users, asset metadata")]
    S3[("S3 / MinIO<br/>ciphertext blobs")]

    CRYPTO -- "encrypted blob + metadata (HTTPS + JWT)" --> ASSETS
    SYNC <-- "delta feed" --> DELTA
    SYNC --> AUTH
    API --> PG
    ASSETS --> S3
```

**Sync sequence**

```mermaid
sequenceDiagram
    participant App as iOS SyncEngine
    participant API as FastAPI
    participant DB as Postgres
    participant S3 as S3/MinIO

    App->>API: PUT /assets/{uuid} (tags, sentiment, ...)
    API->>DB: upsert, bump user.rev
    App->>App: encrypt file (AES-GCM) + SHA-256
    App->>API: PUT /assets/{uuid}/content
    API->>S3: store ciphertext
    API->>DB: mark uploaded, bump rev
    App->>API: GET /sync/changes?since=cursor
    API-->>App: changes (incl. tombstones) + new cursor
```

## Tech stack

| Layer | Technology |
|---|---|
| iOS UI | Swift 5.9, SwiftUI, Observation, SwiftData |
| On-device ML | Core ML, Vision, SoundAnalysis, Speech, NaturalLanguage |
| Crypto / secrets | CryptoKit (AES-GCM), Keychain Services |
| Networking / background | URLSession (async/await), `BGTaskScheduler`, `NWPathMonitor` |
| Backend | Python 3.10+, FastAPI, SQLAlchemy 2.0 (async), Pydantic v2, PyJWT, bcrypt |
| Data | PostgreSQL / Supabase (SQLite for dev), S3 / MinIO via boto3 |
| Tooling | pytest + pytest-asyncio + httpx, Docker Compose, XcodeGen |

## Project structure

```
mediasync/
├── backend/
│   ├── app/
│   │   ├── main.py            # FastAPI app + routers
│   │   ├── config.py          # env-driven settings (MEDIASYNC_*)
│   │   ├── db.py, models.py   # async engine, User & Asset tables
│   │   ├── schemas.py         # Pydantic request/response models
│   │   ├── security.py        # bcrypt + JWT helpers
│   │   ├── deps.py            # current_user dependency
│   │   ├── storage.py         # S3Storage / LocalStorage
│   │   └── routers/           # auth.py, assets.py, sync.py
│   ├── tests/                 # pytest suite
│   ├── Dockerfile
│   └── requirements.txt
├── ios/
│   ├── project.yml            # XcodeGen spec -> MediaSync.xcodeproj
│   └── MediaSync/
│       ├── App/               # app entry, AppState (auth, sync, background)
│       ├── Models/            # SwiftData MediaItem, DTOs
│       ├── Services/          # APIClient, SyncEngine, CryptoService, Keychain, MediaStore
│       ├── ML/                # ImageAnalyzer, AudioAnalyzer, SentimentTagger, ImportService
│       ├── Views/             # Library, Detail, Player, Login
│       └── Utilities/         # Haptics
└── docker-compose.yml         # Postgres + MinIO + API
```

## Getting started

### Prerequisites

- **Backend:** Python 3.10+ (macOS's built-in 3.9 is too old; use `brew install python@3.12`).
- **iOS:** macOS with Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- **Optional:** Docker Desktop for the full Postgres + MinIO stack.

### 1. Backend (no Docker)

Uses SQLite and local disk, so there is nothing else to install.

```bash
cd backend
python3.12 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

export MEDIASYNC_JWT_SECRET=$(openssl rand -hex 32)
MEDIASYNC_STORAGE_BACKEND=local uvicorn app.main:app --reload
```

Open <http://localhost:8000/docs> for the interactive API docs. Data is written to `backend/mediasync.db`
and `backend/.storage/`; delete them to reset.

To reach the API from a physical iPhone, add `--host 0.0.0.0` and use your computer's LAN IP in the app.

### 2. Backend (Docker Compose)

Runs the API with PostgreSQL and MinIO (S3-compatible storage):

```bash
echo "JWT_SECRET=$(openssl rand -hex 32)" > .env
docker compose up --build -d
curl localhost:8000/health        # {"status":"ok"}
```

| Service | URL |
|---|---|
| API + docs | <http://localhost:8000/docs> |
| MinIO console | <http://localhost:9001> (`minioadmin` / `minioadmin`) |

`docker compose down` stops everything; add `-v` to also delete the database and stored files.

### 3. iOS app

```bash
cd ios
xcodegen                      # generates MediaSync.xcodeproj from project.yml
open MediaSync.xcodeproj
```

1. Select the **MediaSync** target → *Signing & Capabilities* → choose your Team.
2. Pick an iPhone simulator (iOS 17+) or a connected device and press **⌘R**.
3. On the login screen keep `http://localhost:8000` for the simulator (use your Mac's LAN IP on a device), create an account, and sign in.
4. Tap **+** to import photos, audio, video or text files and watch them get tagged and synced.

**Optional custom model:** add a Create ML image classifier named `MediaClassifier.mlmodel` to the target.
`ImageAnalyzer` loads it automatically and merges its top label with Apple's built-in taxonomy.

> Audio transcription and sound classification are limited in the simulator; test on a real device for best results.

## Configuration

All backend settings are environment variables prefixed with `MEDIASYNC_` (or put them in `backend/.env`;
see [`backend/.env.example`](backend/.env.example)).

| Variable | Default | Description |
|---|---|---|
| `MEDIASYNC_DATABASE_URL` | `sqlite+aiosqlite:///./mediasync.db` | Use `postgresql+asyncpg://user:pass@host:5432/db` for Postgres/Supabase |
| `MEDIASYNC_JWT_SECRET` | `change-me-in-production` | **Set this.** Use at least 32 random bytes (`openssl rand -hex 32`) |
| `MEDIASYNC_JWT_ALGORITHM` | `HS256` | JWT signing algorithm |
| `MEDIASYNC_ACCESS_TOKEN_MINUTES` | `30` | Access token lifetime |
| `MEDIASYNC_REFRESH_TOKEN_DAYS` | `30` | Refresh token lifetime |
| `MEDIASYNC_STORAGE_BACKEND` | `s3` | `s3` (S3/MinIO) or `local` (disk) |
| `MEDIASYNC_LOCAL_STORAGE_DIR` | `./.storage` | Blob directory for the `local` backend |
| `MEDIASYNC_S3_ENDPOINT_URL` | `http://localhost:9000` | S3 / MinIO endpoint |
| `MEDIASYNC_S3_REGION` | `us-east-1` | S3 region |
| `MEDIASYNC_S3_BUCKET` | `mediasync` | Bucket name (created automatically if missing) |
| `MEDIASYNC_S3_ACCESS_KEY` / `MEDIASYNC_S3_SECRET_KEY` | `minioadmin` | S3 credentials |
| `MEDIASYNC_MAX_UPLOAD_BYTES` | `536870912` | Max upload size (512 MB) |

The iOS API base URL is entered on the login screen and stored in `UserDefaults` (`apiBaseURL`).

## API reference

All endpoints except `/auth/*` and `/health` require `Authorization: Bearer <access_token>`.

| Method | Path | Description |
|---|---|---|
| `POST` | `/auth/register` | Create an account; returns `{access_token, refresh_token}` |
| `POST` | `/auth/login` | Sign in; returns a token pair |
| `POST` | `/auth/refresh` | Exchange a refresh token for a new pair |
| `GET` | `/assets` | List the caller's non-deleted assets |
| `PUT` | `/assets/{uuid}` | Idempotent create/update of metadata (kind, filename, tags, sentiment, ...) |
| `PUT` | `/assets/{uuid}/content` | Upload the encrypted blob as the raw request body. Optional `X-Content-SHA256` header is verified |
| `GET` | `/assets/{uuid}/content` | Stream the encrypted blob |
| `DELETE` | `/assets/{uuid}` | Soft-delete: purges the blob and leaves a tombstone for other devices |
| `GET` | `/sync/changes?since=<rev>&limit=<n>` | Delta feed ordered by revision; returns `{changes, cursor, has_more}` |
| `GET` | `/health` | Liveness check |

Example:

```bash
TOKEN=$(curl -s -X POST localhost:8000/auth/login -H 'content-type: application/json' \
  -d '{"email":"me@example.com","password":"password123"}' | python -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

curl -s "localhost:8000/sync/changes?since=0" -H "Authorization: Bearer $TOKEN"
```

## How it works

**Offline-first sync.** Every import is written to SwiftData and the on-disk cache first, marked `pending`.
`SyncEngine` then:

1. **Push**: for each pending item, upsert metadata, encrypt the file, and upload the ciphertext with its SHA-256. Pending deletions are sent and then removed locally.
2. **Pull**: call `/sync/changes?since=<cursor>` repeatedly until `has_more` is false, applying creates, updates and tombstones, then persist the new cursor.

**Revisions, not timestamps.** Each user has a monotonically increasing `rev` counter that is bumped (atomically) on
every asset change and stamped on the asset. Clients just remember the highest `rev` they've seen, which avoids
clock-skew problems.

**Conflict policy.** Items with unpushed local edits win; otherwise the latest server revision wins. There is no
field-level merge.

**Token handling.** The client keeps tokens in the Keychain and, on a `401`, refreshes once and retries the request.

## Security & privacy model

- **Client-side encryption:** media is sealed with AES-256-GCM (CryptoKit) before upload. The 256-bit key is generated on first use and stored in the Keychain as a *synchronizable* item so iCloud Keychain can share it across your devices. The server cannot decrypt blobs, and **losing the key means losing the uploaded files.**
- **What the server can see:** account email, bcrypt password hash, ciphertext, file size and SHA-256 of the ciphertext, filename, media kind, **tags and sentiment** (needed for cross-device filtering). OCR text and transcripts never leave the device.
- **At rest on device:** plaintext cache uses iOS Data Protection (`.completeFileProtection`).
- **Auth:** short-lived JWT access tokens + refresh tokens; passwords hashed with bcrypt; every query is scoped to the authenticated user and other users' assets return `404`.
- **Transport:** use HTTPS in production. iOS blocks plain HTTP except for local-network development (`NSAllowsLocalNetworking`).
- **Speech:** transcription is forced on-device (`requiresOnDeviceRecognition = true`).

## Testing

```bash
cd backend
source .venv/bin/activate
pip install -r requirements.txt
python -m pytest -q
```

The suite (SQLite + local storage, no external services) covers registration/login/refresh and token-type
enforcement, idempotent upserts, upload/download round trips with checksum validation, cross-user isolation, and
delta sync with cursor pagination and tombstones.

The iOS app currently has no automated tests.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ModuleNotFoundError: fastapi / aiosqlite / pytest_asyncio` | You're outside the virtualenv (e.g. conda `base`). Run `source .venv/bin/activate` and `pip install -r requirements.txt` |
| `TypeError` about `str \| None` on startup | Python is older than 3.10. Use `python3.12 -m venv .venv` |
| `InsecureKeyLengthWarning` from PyJWT | `MEDIASYNC_JWT_SECRET` is shorter than 32 bytes. Set one with `openssl rand -hex 32` |
| App shows "Offline — changes will sync later" | iOS reports no network on the Mac/device. Check Wi-Fi/VPN, or restart the simulator. Sync still attempts to reach your server |
| App can't reach the server from a real iPhone | Use your Mac's LAN IP, start uvicorn with `--host 0.0.0.0`, and be on the same Wi-Fi |
| Repeated sign-in prompts after changing the JWT secret | Expected: old tokens are invalid. Sign in again |
| `email-validator is not installed` | `pip install -r requirements.txt` (it includes `email-validator`) |

## Known limitations

- Whole-file encryption loads the file into memory; large videos need chunked sealing.
- Uploads use a foreground `URLSession`; they are not resumable and won't continue if the app is suspended.
- Tags and sentiment are stored unencrypted on the server by design.
- Refresh tokens are stateless, so there is no server-side revocation/logout.
- The encryption key is only shared via iCloud Keychain; there is no passphrase-based recovery.
- The Docker Compose stack and the Postgres/S3 code paths are not covered by automated tests; the test suite runs on SQLite with local storage.
- No CI, and no automated tests for the iOS app.

## Roadmap

- [ ] Chunked/streaming encryption and resumable background uploads (`URLSessionConfiguration.background`)
- [ ] Refresh-token rotation and server-side revocation
- [ ] Passphrase-derived key backup (HKDF/PBKDF2) for recovery
- [ ] Alembic migrations instead of `create_all`
- [ ] Optional encrypted tags (client-side search index)
- [ ] CI (GitHub Actions) for backend tests and `xcodebuild` on the iOS target
- [ ] XCTest coverage for `SyncEngine` and the ML pipeline
- [ ] Share extension and Live Photo / HEIC handling

## License

Choose a license before publishing (e.g. [MIT](https://choosealicense.com/licenses/mit/)) and add a `LICENSE` file.
