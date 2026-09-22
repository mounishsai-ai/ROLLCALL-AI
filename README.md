# RollCall-AI

**One photograph. Every face accounted for.**

![License: MIT](https://img.shields.io/badge/license-MIT-green)
![Flutter](https://img.shields.io/badge/Flutter-app-02569B?logo=flutter&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-backend-009688?logo=fastapi&logoColor=white)
![Python 3.11](https://img.shields.io/badge/Python-3.11-3776AB?logo=python&logoColor=white)

Classroom attendance from a single group photo — with a live view of the system
reasoning about the faces it can't settle on the first try.

Most face-recognition attendance tools stop at "unknown." RollCall-AI doesn't: a
face the model isn't confident about gets **investigated** — re-cropped,
re-embedded, or escalated to a vision-language model for a second opinion — and
every verdict ships with the reasoning behind it, so a teacher can audit the
decision instead of just trusting it.

## Demo

https://github.com/user-attachments/assets/70181054-f3c7-4ec0-8044-fc96c913900d

> The demo uses publicly available photos of **well-known actors as stand-in
> students**. Real faces are biometric data, so keeping them out of a public
> video is a deliberate privacy choice — the same principle the app applies to
> real deployments (see [Before you run this on real people](#before-you-run-this-on-real-people)).
> To run the app yourself, see [Running it locally](#running-it-locally).

## What makes it more than a face-matcher

- **It investigates instead of guessing.** The faces a model can't settle — the
  small, blurry, half-turned ones at the back of any classroom — go through an
  *Adjudicator* loop that picks a tool per face: a free re-crop first, and a
  vision-language model (Gemini) only if that fails.
- **It is allowed to say "none of these."** An open room contains people who
  aren't on the roster. The system reports a stranger rather than pinning them on
  whoever happened to score highest.
- **A failed check is never a wrong answer.** A network error or timeout is a
  third state, not a silent "that isn't them" — so a glitch never marks a present
  student absent.
- **It flags its own decay.** When a student's stored photo only just matches, the
  register says *time for a new photo* — catching the slow drift as people grow
  beards or change glasses, before it quietly breaks their attendance.
- **A scan proposes; a person signs.** Nothing is recorded until a teacher
  confirms it, and that rule is enforced in the API, not just the interface.

## How it works

1. **Capture** — one photo of the room, from the Flutter app's camera.
2. **Detect** — RetinaFace locates every face in the frame.
3. **Embed** — ArcFace or AdaFace turns each face into a vector.
4. **Match** — FAISS does a cosine-similarity search against the enrolled roster.
5. **Adjudicate** — matches the model isn't sure about are re-cropped, re-embedded, or shortlisted to Gemini Vision (via Vertex AI) for a second opinion, rather than being guessed at.
6. **Verdict** — present / absent / unsure, each with its reasoning, logged to the register.

Faces that match nobody on the roster are reported, not silently dropped — somebody was in the room.

## Architecture

```
Flutter web app (Firebase Hosting)
        │  photo upload, authenticated with a shared key
        ▼
FastAPI backend on Cloud Run ─────►  Firestore
        │                              ├─ roster
        ├─ RetinaFace (detection)      ├─ attendance log
        ├─ ArcFace / AdaFace (embed)   └─ face vectors (512-D)
        ├─ FAISS — in-memory search, rebuilt from Firestore at startup
        └─ Adjudicator loop ──► Gemini Vision (Vertex AI, second opinion)
```

Face vectors live in Firestore rather than in an index file on disk. A container's
disk does not survive a restart, so FAISS is treated as what it is good at — a fast
search structure over vectors something else is keeping safe.

## Tech stack

| Layer | Technology |
|---|---|
| Frontend | Flutter (Android / iOS / Web) |
| Backend | FastAPI (Python), async workers |
| Face detection | RetinaFace |
| Face embedding | ArcFace / AdaFace |
| Vector search | FAISS (cosine similarity) |
| Agentic reasoning | Custom Adjudicator loop + Gemini Vision (Vertex AI) |
| Database | Firebase Firestore (roster, attendance, face vectors) |
| API hosting | Google Cloud Run |
| App hosting | Firebase Hosting |
| Access control | Shared API key, checked on every request |

## Running it locally

**Backend**

```bash
cd backend
pip install -r requirements.txt
python download_model.py          # pulls the AdaFace checkpoint
cp .env.example .env              # fill in your own Firebase + Vertex config
uvicorn main:app --reload
```

Needs a Firebase service account key (`serviceAccountKey.json`) and a GCP project with the Vertex AI API enabled — see `backend/.env.example` for every variable.

**Frontend**

```bash
cd frontend
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

Leave `API_KEY` unset in `backend/.env` for local development and the API runs open;
set it and every request — including the face images — needs the key. The startup log
says which mode it is in, every time.

## Before you run this on real people

This is face recognition. It takes photographs of people, turns their faces into
biometric data, and stores it. Whoever deploys it — not the author of this code —
is responsible for what happens next:

- **Get consent.** Everyone whose face is enrolled should know it is happening,
  what it is for, and how to have it removed. Students are not in a position to
  object easily, which makes asking properly more important, not less.
- **Face crops and registration photos are sent to Google** when the system is
  unsure and asks Gemini for a second opinion. That is a design choice, it is
  documented, and it should be disclosed to the people in the photographs.
- **Biometric data is regulated** in many places, and rules differ by country and
  by institution. Check what applies to you before enrolling anyone.
- **Deletion should be real.** `DELETE /students/{reg}` removes the photograph
  and every stored face vector across all backends. If someone asks to be
  removed, that is the button.

Nothing here should be used to track attendance without the knowledge of the
people being tracked.

## Third-party components

The source code in this repository is MIT-licensed (see [LICENSE](LICENSE)). It
builds on open-source components, each under its own license, among them:

- **RetinaFace** (face detection) and **ArcFace** via **DeepFace** (embeddings)
- **AdaFace IR-50** (embeddings, PyTorch)
- **FAISS** (vector search)
- **Flutter** (app) and **FastAPI** (backend)
- **Google Gemini** via **Vertex AI** (optional second opinion)

The MIT license here covers this project's own code only. The pretrained
face-recognition **model weights** (ArcFace, AdaFace) are trained on third-party
datasets and commonly carry **research / non-commercial-only** terms. They are
not redistributed in this repository, and this project's license grants no right
to use them. **Check each model's and dataset's own license before any
commercial use.**

## Author

Built by **N. Mounish Sai** — Dept. of Computer Science & Engineering, Vignan's Foundation for Science, Technology & Research.
