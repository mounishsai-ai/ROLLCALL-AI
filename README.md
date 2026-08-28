# RollCall-AI

**One photograph. Every face accounted for.**

Classroom attendance from a single group photo — and a live view of the system reasoning about the faces it can't settle on the first try.

Most face-recognition attendance tools stop at "unknown." RollCall-AI doesn't: a face the model isn't confident about gets investigated — re-cropped, re-embedded, or escalated to a vision-language model for a second opinion — and every final verdict ships with the reasoning behind it, so a teacher can audit the decision instead of just trusting it.

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
Flutter app (Android / iOS / Web)
        │  photo upload
        ▼
FastAPI backend  ──────────────►  Firestore (roster + attendance log)
        │
        ├─ RetinaFace (detection)
        ├─ ArcFace / AdaFace (embedding)
        ├─ FAISS (vector search)
        └─ Adjudicator loop ──► Gemini Vision (Vertex AI, second opinion)
```

## Tech stack

| Layer | Technology |
|---|---|
| Frontend | Flutter (Android / iOS / Web) |
| Backend | FastAPI (Python), async workers |
| Face detection | RetinaFace |
| Face embedding | ArcFace / AdaFace |
| Vector search | FAISS (cosine similarity) |
| Agentic reasoning | Custom Adjudicator loop + Gemini Vision (Vertex AI) |
| Database | Firebase Firestore |
| Deployment | Google Cloud Run |

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
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

## Team

| Name | Reg. No. |
|---|---|
| N. Mounish Sai | 241FA04D58 |
| P. Irfan Khan | 241FA04803 |
| T. Bala Jaison | 251LA04007 |

Dept. of Computer Science & Engineering — Vignan's Foundation for Science, Technology & Research
