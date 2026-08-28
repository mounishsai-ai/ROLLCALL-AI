# AGENTS.md — Smart AI Attendance System

Read this first. It replaces the old `context.md` (deleted 2026-08-26).
Architecture and data flow live in [system_design.md](system_design.md); the runbook lives in [instructions.md](instructions.md).

---

## 1. What this project is

A classroom attendance app. A teacher takes **one group photo**; the system finds every face, matches each one to a registered student, and marks Present / Unsure / Absent.

**Goal: win the Agent Expo.** The system must not just work — it must visibly *reason*. See §7.

- **Frontend** — Flutter (`frontend/`), dark slate theme, mobile + Chrome.
- **Backend** — Python FastAPI (`backend/`), runs on the developer's laptop.
- **Metadata** — Firebase Firestore (students, attendance logs).
- **Vectors** — FAISS, on local disk, one index per recognition backend.
- **Adjudication** — the Adjudicator loop (§7) investigates every face the maths could not settle, using Gemini via **Vertex AI** as its second opinion.

---

## 2. How to work with this repo's owner

The owner is a **student vibe coder** who learns by building with AI. This changes how you write, not what you build.

- **Explain like a smart beginner, not a developer.** Plain words. Say what a thing *does* before naming it. No unexplained jargon, no "as you know."
- **Show the why.** A one-line reason beats a paragraph of theory.
- **Don't lecture.** If something is broken, say what breaks, when, and the fix.
- Never dumb down the *code*. Beginner tone, professional engineering.

### Model routing (the owner's plan)

| Work | Model |
|---|---|
| Frontend / UI design | **Opus** + the `frontend-design` skill — always both |
| Core architecture, system design | **Opus** |
| Anything gnarly, subtle, or expo-critical | **Opus** |
| Routine implementation, refactors, wiring | **Sonnet** |
| Sonnet got stuck or produced something wrong | Escalate to **Opus** as advisor |

**Rule: any UI or frontend work loads the `frontend-design` skill before writing widgets.** The expo is judged partly on how it looks; templated Material defaults lose.

---

## 3. Repo layout

```
backend/
  main.py                      FastAPI routes + lifespan startup
  sync_faces.py                CLI: sync or rebuild a FAISS index
  download_model.py            Fetches the AdaFace checkpoint
  services/
    base_face_service.py       ★ The core. FAISS, queue, per-face analysis.
    adjudicator.py             ★ The agentic loop — investigates uncertain faces
    job_store.py               In-memory scan jobs + the live reasoning trace
    deepface_service.py        ArcFace backend (embedding only)
    adaface_service.py         AdaFace IR-50 backend (embedding only)
    adaface_net.py             AdaFace network definition
    vlm_service.py             Gemini (Vertex AI or API key), second opinions
    firebase_db.py             Firestore reads/writes
    azure_face.py              ⚠️ DEAD CODE — see §6
  known_faces/
    <reg>.jpg                  Shared across backends
    arcface/  faiss.index + id_map.json
    adaface/  faiss.index + id_map.json
frontend/lib/
  main.dart                    App shell + HomeScreen + server settings
  theme/examination.dart       Design tokens for the scan + register screens
  models/scan_event.dart       Reasoning-trace events, grouped per face
  services/api_service.dart    All HTTP calls
  screens/
    scan_screen.dart           ★ The live reasoning trace
    result_screen.dart         The register — every verdict with its reason
    splash, camera, register, manage_students
```

`base_face_service.py` is where almost every meaningful change lands. Both backends inherit it and only implement `_extract_embeddings()`.

---

## 4. History — how it got here

1. Started as basic DeepFace + ArcFace recognition.
2. **AdaFace IR-50** added as a higher-accuracy option, chosen because it is *quality-adaptive* — it handles the blurry, small, side-angle faces you get at the back of a group photo.
3. **Strategy pattern**: `BaseFaceService` + two interchangeable subclasses, switched by `FACE_RECOGNITION_BACKEND` in `.env`.
4. **Background registration**: embedding extraction moved to a `ThreadPoolExecutor` so the API returns instantly.
5. **Unified detection**: RetinaFace for both registration and attendance, so both sides produce the same 112×112 canonical crop. CLAHE added for lighting.
6. **`sync_faces.py`**: backfills or rebuilds an index from Firebase or local images.
7. **Dual status badges** in the Flutter UI, so you can see at a glance which index holds a given student.
8. **Gemini VLM tier** added — a second opinion on faces FAISS is unsure about. Documented in `system_design.md` §VLM.
9. **Freeze fixes** (2026-08-26): the scan moved off the event loop, Gemini calls got a hard timeout and a startup warm-up, and failures became a distinct third state instead of a silent "no".
10. **The Adjudicator** (2026-08-26): the pipeline's uncertain faces now go through an investigation loop that picks a tool per face and streams a live reasoning trace. See §7.
11. **Vertex AI migration** (2026-08-26): moved off the deprecated `google-generativeai` package and off the AI Studio free tier, onto `google-genai` talking to Vertex on GCP project `smart-attendance-37133`. The free tier had `gemini-3.7-flash` returning "503 high demand" for minutes at a time; the same model over Vertex answers in ~3.5s.

---

## 5. Non-obvious rules (break these and things silently fail)

- **OpenMP crash on Windows.** PyTorch (AdaFace) and TensorFlow (RetinaFace) in one process fight over `libiomp5md.dll` and kill the server with no error. `os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"` sits at the very top of `main.py`, **before any other import**. Never move it.
- **Firebase is model-agnostic; FAISS is model-specific.** A student in Firestore is not necessarily in the active index. Switching backends requires `sync_faces.py`.
- **One backend is active per API process.** Changing `.env` needs a restart.
- **Registration images must contain exactly one face.** Two faces = rejected, on purpose — otherwise a bystander gets bound to that student's ID.
- **A new registration only updates the *active* backend.** The other index goes stale until synced.
- **Rebuild after any change to alignment, preprocessing, or model files.** If everyone suddenly reads Absent, rebuild the index — do *not* just lower the thresholds.
- **RetinaFace's `left_eye` is the subject's left**, which is on the *viewer's right*. `adaface_service.py` reorders landmarks to match the ArcFace template. Get this backwards and faces come out near-180°-rotated with garbage embeddings.
- **`.env` reads `FACE_MATCH_MARGIN`**, not `DEEPFACE_MATCH_MARGIN`. The old `.env.example` had the wrong name; fixed 2026-08-26.
- **RetinaFace builds a TensorFlow graph per input *shape*.** A new image size costs tens of seconds, once, on this CPU-only laptop. That is why the Adjudicator letterboxes every re-crop onto a fixed `ADJ_RESCAN_CANVAS_PX` canvas, and why `warm_up()` runs a detection at that exact size at startup. Feeding arbitrary sizes silently reintroduces minute-long scans.
- **Before demoing: start the backend early and take one throwaway scan.** Startup warms Firestore, Gemini and the detector in the background (a few minutes on this laptop), and the first scan at the camera's own resolution still pays one graph build for *that* shape. Measured here on a 1500×760 test photo: first scan ~140 s, every scan after ~55 s, re-crops ~7 s once warm, and the synchronous fallback route 16 s.
- **Those timings have not been measured on a real phone photo**, which is a much larger shape than anything the warm-up covers. Take one full-resolution scan and time it before trusting them. If it is bad, the fix is the same normalisation already used for re-crops: downscale the uploaded photo to a fixed maximum dimension before detection, so the main path's shape is constant too.

---

## 6. Known problems

### Fixed (2026-08-26)

| # | Was | Now |
|---|---|---|
| 1 | `take_attendance` blocked the event loop | Runs in a worker thread. The agentic route returns a job id in milliseconds and never holds a request open at all. |
| 2 | Gemini ~14s warm / 126s cold vs a 120s client timeout | Vertex answers in ~3.5s; per-call timeouts, a startup warm-up, and job polling remove the timeout class entirely. |
| 3 | VLM only saw faces *above* `unsure_threshold` | The Adjudicator investigates the `unrecognized` tier too, and can conclude "not enrolled". |
| 4 | VLM only confirmed/denied the **top-1** guess | `identify_among_candidates()` shows a shortlist and lets Gemini name a different student. Corrections are flagged in the trace and the register. |
| 5 | `verify_match()` returned `False` on any exception | Tri-state `yes`/`no`/`error` throughout; `error` never becomes a rejection. |
| 7 | `google-generativeai` deprecated | Migrated to `google-genai` on Vertex AI. |

### Still open

| # | Problem | Impact |
|---|---|---|
| 6 | `azure_face.py` is unreferenced and imports `azure-ai-vision-face`, which is **not** in `requirements.txt` | Dead code. Delete it or it will confuse a judge reading the repo. |
| 8 | Frontend `pubspec.yaml` still says `description: "A new Flutter project."` | Sloppy detail a judge may see. |
| 9 | **Student `6` is missing from the AdaFace index** (present in ArcFace, photo on disk) | In AdaFace mode they can never be recognised and are silently marked absent every scan. Run `python sync_faces.py` before the demo, and check both indexes hold every student. |
| 10 | A face whose true student is not in the FAISS shortlist can be reported "not enrolled" | The shortlist comes from vector neighbours, so if the embedding is bad enough that the right person never ranks, Gemini is never shown them. Rare, but it is the honest limit of the current loop. |

---

## 7. The Adjudicator — where the "agent" actually is

The recognition pipeline (detect → embed → search → threshold) always runs the same steps in the same order and answers every face with a number. That is fine when the number is decisive and useless when it is not. The Adjudicator (`services/adjudicator.py`) handles the faces where it is not.

**The loop, per face.** Faces are worked in parallel; tools within one face run in sequence, because each choice depends on what the last one found.

1. **Look at what it actually has** — face size in pixels, sharpness (variance of the Laplacian), how close the runner-up scored. Free, local, instant.
2. **Choose a tool from that.** A small or soft face is a *picture* problem → re-crop it from the full-resolution photo, upscale, re-detect, re-embed. A large sharp face that is still ambiguous is an *identity* problem → go straight to a second opinion.
3. **Re-check.** If the re-crop settled it, stop — no Gemini call is spent. This is the agent choosing the cheap tool and it paying off, and it happens often.
4. **Escalate** what survives: show Gemini the face plus a shortlist of plausible students and ask which one it is, **or none of them**.
5. **Resolve** — present / not enrolled / left for a human.

**Non-negotiable properties:**

- **Keyed by `face_id`, never by student.** Two faces in one photo can produce the same top-1 guess; identity-keyed state silently merges them.
- **"None of these" is a real verdict**, separate from "the check failed". An open room contains people who are not on the roster. A system that cannot say so will pin a stranger on whoever scored highest — the single worst thing a judge could make it do.
- **A failed check is never a rejection.** `error` leaves the face unresolved.
- **Bounded.** `ADJ_MAX_INVESTIGATIONS` faces, `ADJ_TIME_BUDGET_SECONDS` wall clock, best-scoring faces first.

**The trace.** Every observation, decision and outcome is emitted through `job_store.py` as it happens, with a thumbnail of the face being discussed, and rendered live by `scan_screen.dart`. The loop is what makes the trace honest; the trace is what makes the loop visible. They only work together.

**Deliberately not built:** trying the *other* embedding backend. Only one is loaded per process (§5), and loading PyTorch and TensorFlow together is what `KMP_DUPLICATE_LIB_OK` is already papering over. Re-crop plus shortlist-identify is enough for the loop to visibly choose.

**Transport.** `POST /take_attendance_agentic` returns a `job_id` immediately; `GET /attendance_job/{id}?since=N` returns everything since event N. The old synchronous `POST /take_attendance` is untouched and still works — if anything misbehaves mid-demo, it is one call away.

---

## 8. Commands

```powershell
# Backend (from backend/)
python -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload

# Frontend tests (from frontend/)
flutter test

# If Gemini stops answering, check the credentials before touching any code
gcloud auth application-default print-access-token | Out-Null; echo $?

# Frontend (from frontend/)
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000

# Rebuild the active index after any pipeline change (API must be stopped)
python sync_faces.py --rebuild-local
```

Full runbook with prerequisites, phone/emulator URLs, and troubleshooting: [instructions.md](instructions.md).

---

## 9. Safety and data

- `backend/.env` and `backend/serviceAccountKey.json` hold live secrets. Both are gitignored. **Never** print, commit, or paste their contents.
- `known_faces/` holds photographs of real students. Gitignored. The Adjudicator uploads face crops **and registration photos** to Google when it asks for a second opinion — that is a deliberate design choice and should be disclosed in the expo demo.
- Gemini runs on GCP project `smart-attendance-37133` via Application Default Credentials. If `VERTEX_PROJECT` is ever unset, the service silently falls back to the throttled AI Studio free tier rather than failing — check the startup log line, which names the transport in use.
