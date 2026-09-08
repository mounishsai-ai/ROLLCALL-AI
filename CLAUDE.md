# CLAUDE.md — Smart AI Attendance System (RollCall-AI)

Read this first. It is the single working agreement for this repo.
It replaces `AGENTS.md` (renamed 2026-09-08) and the old `context.md` (deleted 2026-08-26).

**Two other docs exist, and only two. Each has one job:**

| Doc | Job | Go there for |
|---|---|---|
| **CLAUDE.md** (this) | Working agreement, architecture, runbook | Why things are the way they are, what not to break, how to run it |
| [system_design.md](system_design.md) | Data flow + diagrams | Mermaid sequence/flow charts, Firestore schema, threshold maths |
| [README.md](README.md) | Public face | What a stranger or a judge reads first |

`AGENTS.md` holds one line pointing here, so an agent that looks for it by name is not left with nothing.

**Deleted 2026-09-08:** `instructions.md` (its runbook is now §10 — the old one had a typo'd path, thresholds that contradicted `.env.example`, and described an event-loop freeze fixed weeks earlier), `frontend/README.md` (untouched Flutter template), `googlecloud,gemini.md` (folded into §1).

If a fact belongs in two of them, it lives in **one** and the other links to it. See §9.

---

## 1. What this project is

A classroom attendance app. A teacher takes **one group photo**; the system finds every face, matches each one to a registered student, and marks Present / Unsure / Absent.

**Goal: win the Agent Expo.** The system must not just work — it must visibly *reason*. See §7.

There are **$300 of Google Cloud credits** available for this. They exist to be spent: use them to reach the strong Gemini models through Vertex AI (real quota, no free-tier throttling) and any other Cloud service that makes the demo land harder. The look and feel should be as close to sci-fi as the substance can honestly support — but the substance comes first, and every claim in the demo has to be true.

- **Frontend** — Flutter ([frontend/](frontend/)), dark petrol-and-amber theme, mobile + Chrome.
- **Backend** — Python FastAPI ([backend/](backend/)), runs on the laptop for development and on **Cloud Run** for the demo.
- **Access** — one shared key on every request ([services/auth.py](backend/services/auth.py)). See §11.
- **Data** — Firebase Firestore holds students, attendance logs, **and face vectors**.
- **Search** — FAISS, built in memory at startup from the vectors in Firestore. Nothing on disk.
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

## 3. The whole system in one pass

Five moving parts. Nothing else.

```
 +--------------+   1. one photo + access key
 | Flutter app  |----------------------+
 | (phone/web)  |<---- verdicts -------+
 +--------------+                      |
                                       v
                              +------------------+
                              | FastAPI backend  |
                              | laptop :8000, or |
                              | Cloud Run (1x)   |
                              +--------+---------+
             +-------------------------+--------------------------+
             v                         v                          v
   +------------------+      +------------------+      +--------------------+
   | RetinaFace       |      | FAISS            |      | Firestore          |
   |  + ArcFace or    |      |  IN MEMORY ONLY  |      |  names, reg nos,   |
   |    AdaFace       |----->|  cosine search   |<-----|  attendance log,   |
   | turns a face     |      |  rebuilt at      | load |  FACE VECTORS      |
   | into 512 numbers |      |  startup         |      +--------------------+
   +------------------+      +------------------+          the only durable
                                       |                   store there is
                                       | unsure faces only
                                       v
                              +------------------+
                              | Gemini (Vertex)  |  the second opinion
                              +------------------+
```

**The idea in one paragraph.** A face-recognition model does not recognise faces; it turns a face into a list of 512 numbers, and two photos of the same person produce two similar lists. FAISS is a database that answers "which stored list is closest to this one?" quickly. Closeness is a score from 0 to 1. A high score is a match, a low score is not, and the interesting part of this project is everything in between — because that middle band is where a classroom photo actually lives: small faces at the back, motion blur, a head turned away. The Adjudicator (§7) is what handles that band.

**Three tiers, one rule** (`classify_score` in [base_face_service.py](backend/services/base_face_service.py)):

| Tier | Condition | Meaning |
|---|---|---|
| `confident` | score >= match threshold **and** clear of the runner-up by the margin | Present, no further checks |
| `uncertain` | score >= unsure threshold | Investigate |
| `unrecognized` | below both | Investigate — could be a bad crop, could be a stranger |

The margin matters as much as the score: a face that scores 0.42 against two different students is ambiguous even though 0.42 clears the line.

**Two attendance routes, on purpose:**

| Route | Shape | Use |
|---|---|---|
| `POST /take_attendance_agentic` | Returns a `job_id` in milliseconds; client polls `GET /attendance_job/{id}?since=N` | **The demo.** Reasoning streams live. Cannot time out. |
| `POST /take_attendance` | Blocks until done, returns the answer | **The parachute.** If anything misbehaves mid-demo, this is one call away. |

Do not add a third. See §9.

**A scan is a proposal, not a record.** `POST /attendance/confirm` is what a
teacher signs off, and only that sets `confirmed_by_teacher`. A scan writing
straight to the register was fine for a demo and wrong for anything a student's
attendance depends on — the machine suggests, a person decides. The confirm
route validates against the live roster and needs no face model, so it works
while one is still loading.

---

## 4. Repo layout

```
backend/
  main.py                      FastAPI routes + lifespan startup
  sync_faces.py                CLI: sync or rebuild vectors, one backend or both
  download_model.py            Fetches the AdaFace checkpoint
  Dockerfile                   Cloud Run image (bakes model weights in)
  deploy_backend.ps1           Cloud Run deploy - PowerShell, and the instance counts are load-bearing
  services/
    base_face_service.py       * The core. Search, queue, per-face analysis.
    adjudicator.py             * The agentic loop - investigates uncertain faces
    auth.py                    The shared-key check, as middleware
    job_store.py               In-memory scan jobs + the live reasoning trace
    deepface_service.py        ArcFace backend (embedding only)
    adaface_service.py         AdaFace IR-50 backend (embedding only)
    adaface_net.py             AdaFace network definition
    vlm_service.py             Gemini (Vertex AI or API key), second opinions
    firebase_db.py             Firestore: roster, attendance, AND face vectors
  known_faces/                 gitignored - real students' photographs
    <reg>.jpg                  Shared across backends. Images only; no index files.
frontend/lib/
  main.dart                    App shell + HomeScreen + server settings
  theme/examination.dart       Design tokens for the whole app
  models/scan_event.dart       Reasoning-trace events, grouped per face
  services/api_service.dart    All HTTP calls
  screens/
    scan_screen.dart           * The live reasoning trace
    result_screen.dart         * The register - evidence, checkboxes, sign-off
    splash, camera, register, manage_students
frontend/test/                 3 widget/unit tests - the only tests in the repo
```

[base_face_service.py](backend/services/base_face_service.py) is where almost every meaningful change lands. Both recognition backends inherit it and only implement `_extract_embeddings()`.

### How the backend is put together

Three layers, and they do not reach past each other:

1. **Routes** ([main.py](backend/main.py)) — parse the request, call a service, shape the JSON. No business logic. Every response is `{"status": ...}` plus data; every error is `{"status": "error", "error": {code, message, details}}`, produced by three exception handlers so no route writes its own error shape.
2. **Services** ([backend/services/](backend/services/)) — all the actual work. Each owns one concern and knows nothing about HTTP.
3. **Storage** — FAISS on disk, Firestore over the network. Only services touch them.

The recognition backends use the **strategy pattern**: `BaseFaceService` is an abstract class holding everything shared (index management, the background registration queue, CLAHE preprocessing, scoring rules), and `DeepFaceService` / `AdaFaceService` each supply one method. Swapping models is one env var and a restart. This is the single best structural decision in the repo — the alternative is two 700-line files that drift apart.

**Concurrency, in plain terms.** Face recognition is slow and Python's web server handles one thing at a time by default, so anything slow must be moved off the main line or the whole API freezes:

- Registration → a one-worker background queue, so the API answers instantly and the embedding is computed after.
- Sync attendance → `asyncio.to_thread`, so the scan runs on a side thread.
- Agentic attendance → a full background job with an event log the client polls. The upload returns immediately, so a slow scan can never trip a client timeout.
- Inside one scan → faces are investigated in parallel (a thread pool), but the tools *within* one face run in order, because each choice depends on what the last one found.

### How the frontend is put together

Deliberately plain, and that is the right call at this size:

- **`ApiService`** — all HTTP in one static class. Every call has an explicit timeout and goes through one `_parseJsonResponse` that understands the backend's error envelope, so no screen ever parses JSON itself. Base URL resolves in order: saved setting → compile-time `--dart-define` → platform default (`10.0.2.2` on Android emulator, `127.0.0.1` elsewhere).
- **State** — plain `StatefulWidget` + `setState`. **No Provider, Riverpod, Bloc or GetX**, on purpose: this app has six screens and no shared state worth lifting. Adding a state-management package here would be architecture for its own sake.
- **`ScanProgress` / `ScanEvent`** ([models/scan_event.dart](frontend/lib/models/scan_event.dart)) — the one real model. It takes the flat event stream from the backend and groups it per face, so each face becomes a card that fills in over time instead of a scrolling log.
- **`ReasoningTrace`** is split out of `ScanScreen` specifically so the layout can be rendered in a test without a server — `ScanScreen` starts a scan the moment it is built.
- **Theme** ([theme/examination.dart](frontend/lib/theme/examination.dart)) — every colour, type style and surface is a token on one `Ex` class. Deep petrol-to-navy with one warm amber accent; explicitly no purple-to-pink gradient, because that is the most generic thing a dark app can wear. Colours carry meaning: amber = still working, green = settled, coral = not on the roster, cool grey = no answer reached. System fonts only, so bad venue wi-fi cannot change how it looks.

### The register screen is where the product actually lives

[result_screen.dart](frontend/lib/screens/result_screen.dart) is the screen a
teacher uses and the one a non-technical judge understands. Three decisions in
it are deliberate:

- **Every row leads with evidence, not the name.** Two square photos butted
  together with one hairline — *on file* and *in the room*. The app uses discs
  for faces everywhere else; a disc is an avatar and says "this is a person",
  a square plate is evidence and says "these two are being compared". Nobody can
  audit a similarity score, but anyone can look at two faces.
- **Sections say how the verdict was reached**, not just what it was: matched
  instantly / the system worked these out / left for you / not on the roster /
  not found. Within each, sorted by registration number read as a *number*, so 2
  comes before 10.
- **Pre-ticked from the scan.** Agreeing costs no taps, disagreeing costs one.

**Face drift** is flagged here too: a student who only just scraped a match, or
needed a re-crop, or needed Gemini, gets "time for a new photo". People grow
beards and change glasses, their stored vector quietly stops matching, and the
system degrades for months before anyone notices. Catching that early is the
most genuinely useful thing this project does, and it costs one comparison
against a score that was already computed. The threshold (0.55) is a guess and
should be calibrated against a real class photo.

**Where this stops being fine:** [scan_screen.dart](frontend/lib/screens/scan_screen.dart) is 859 lines and [manage_students_screen.dart](frontend/lib/screens/manage_students_screen.dart) is 401. If a screen passes roughly 400 lines, or if two screens start needing the same piece of live state, that is the signal to pull widgets into their own files — not before.

---

## 5. History — how it got here

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
12. **Docs consolidated** (2026-09-08): six root documents down to three. `AGENTS.md` became this file; `googlecloud,gemini.md` folded into §1; `instructions.md` and `frontend/README.md` deleted. Full codebase audit recorded in §8.
13. **Vectors moved to Firestore** (2026-09-08): the on-disk `faiss.index` files are gone. Firestore holds every face vector; FAISS is rebuilt in memory at startup. This is what makes the backend safe to run anywhere — a container's disk does not survive a restart, and the Cloud Storage mount was never a safe home for an index file. Migrated with `sync_faces.py --all-backends --import-legacy-index`, verified bit-identical.
14. **Access control** (2026-09-08): one shared key on every request, checked in middleware so the `/faces` photo mount is covered too. CORS narrowed to the hosting origin and `allow_credentials` turned off.
15. **Deployed** (2026-09-08): Cloud Run for the API, Firebase Hosting for the Flutter web build. See §10.
16. **Made it actually usable in the cloud** (2026-09-08): three things that only show up once deployed — background model loading so the roster does not wait for machinery it never uses, `--no-cpu-throttling` so the agentic scan's background thread actually runs, and both backends loaded so registration and deletion cover them without a script. Two things bit during the first deploys and are written down in §6 so they do not bite twice: Git Bash mangling container paths, and `opencv-python==4.9` being unusable with NumPy 2 in a clean container while the laptop was fine on 4.13.

---

## 6. Non-obvious rules (break these and things silently fail)

- **OpenMP crash on Windows.** PyTorch (AdaFace) and TensorFlow (RetinaFace) in one process fight over `libiomp5md.dll` and kill the server with no error. `os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"` sits at the very top of `main.py`, **before any other import**. Never move it.
- **The roster is model-agnostic; vectors are model-specific, and never interchangeable.** ArcFace's numbers and AdaFace's numbers describe the same face in two languages that share no vocabulary. Measured on this project's own data: the same student's vector against itself in one model scores **1.0000**; the same student *across* the two models scores **0.016 on average** — indistinguishable from two strangers. Cosine similarity only means anything inside one model's space.

  Both sets live in Firestore's `face_embeddings` collection tagged by backend, and every read filters on that tag. Registering one photo into both backends means **running both models over it** and storing two independent vectors. Copying a vector from one backend to the other would make every later match noise — never do it; regenerate from the photograph with `sync_faces.py --all-backends` instead.
- **One backend is active per API process.** Changing `.env` needs a restart.
- **Registration images must contain exactly one face.** Two faces = rejected, on purpose — otherwise a bystander gets bound to that student's ID.
- **Registration and deletion now reach every backend automatically.** The server loads *both* ArcFace and AdaFace, and `/register_student` enrols into all of them while `DELETE /students/{reg}` removes from all of them. Switching `FACE_RECOGNITION_BACKEND` is now just a restart — no script, nothing to remember.
  `sync_faces.py --all-backends` is still worth keeping for **backfilling students registered before this changed**, and after any pipeline change (`--rebuild-local`). It is no longer part of normal use.
  The cost of this is memory: two models in one process, which is why Cloud Run asks for 8Gi. If a secondary backend fails to load, the server says so and keeps working — you lose dual registration, not the demo.
- **Nothing about the index is on disk any more.** No `faiss.index`, no `id_map.json`. If you find code reading those, it is stale — vectors come from Firestore and FAISS is rebuilt in memory at startup.
- **There are two photo stores and they do not sync themselves.** Vectors are shared (Firestore), photographs are not:

  | Where | Path | Written by |
  |---|---|---|
  | Laptop | `backend/known_faces/` | Local backend |
  | Cloud Run | `gs://smart-attendance-37133-known-faces` (mounted at `/app/known_faces`) | Deployed backend |

  **The bucket is authoritative** — it is what the demo runs on. A student registered locally has a vector everybody can see and a photo only the laptop has, which matters because the Adjudicator sends *registration photos* to Gemini: a missing photo means that student can never be offered as a candidate. After registering anyone locally, push the images up:

  ```powershell
  gcloud storage cp known_faces\*.jpg gs://smart-attendance-37133-known-faces/ --project=smart-attendance-37133
  ```

  The honest fix, when this stops being a demo, is to stop keeping photos in two places — have the local backend read and write the bucket too.
- **Rebuild after any change to alignment, preprocessing, or model files.** If everyone suddenly reads Absent, rebuild the index — do *not* just lower the thresholds.
- **RetinaFace's `left_eye` is the subject's left**, which is on the *viewer's right*. `adaface_service.py` reorders landmarks to match the ArcFace template. Get this backwards and faces come out near-180°-rotated with garbage embeddings.
- **`.env` reads `FACE_MATCH_MARGIN`**, not `DEEPFACE_MATCH_MARGIN`. The old `.env.example` had the wrong name; fixed 2026-08-26.
- **RetinaFace builds a TensorFlow graph per input *shape*.** A new image size costs tens of seconds, once, on this CPU-only laptop. That is why the Adjudicator letterboxes every re-crop onto a fixed `ADJ_RESCAN_CANVAS_PX` canvas, and why `warm_up()` runs a detection at that exact size at startup. Feeding arbitrary sizes silently reintroduces minute-long scans.
- **Measured on the deployed service (2026-09-08):** a warm scan of a single-face photo finished in **3.7s** end to end — detect, embed, search, verdict — with the job id returned in milliseconds. That is the number to quote. It does not include a cold start, which is the next bullet.
- **Before demoing: start the backend early and take one throwaway scan.** Startup warms Firestore, Gemini and the detector in the background (a few minutes on this laptop), and the first scan at the camera's own resolution still pays one graph build for *that* shape. Measured here on a 1500×760 test photo: first scan ~140 s, every scan after ~55 s, re-crops ~7 s once warm, and the synchronous fallback route 16 s.
- **Those timings have not been measured on a real phone photo**, which is a much larger shape than anything the warm-up covers. Take one full-resolution scan and time it before trusting them. If it is bad, the fix is the same normalisation already used for re-crops: downscale the uploaded photo to a fixed maximum dimension before detection, so the main path's shape is constant too.

### Never mutate before you know you can finish

`DELETE /students/{reg}` used to remove the roster row, *then* ask for the face backends — and 503 if they were still loading. On a container that had scaled to zero that produced a **half-deleted student**: off the roster, vector still in the index, invisible to the app and impossible to clean up through it. It happened for real, to student `6`.

Two rules came out of it:

1. **Check everything you need before changing anything.** If a route can refuse, it must refuse before the first write.
2. **Better: don't need the thing.** Deletion turned out to require no model at all — every durable part is a database row or a file, and the models only hold a searchable copy. So it now deletes unconditionally and tells whichever backends happen to be loaded afterwards. A route that cannot fail halfway is better than one that fails halfway carefully.

Worth checking for orphans after any incident like this: every reg number in `face_embeddings` should exist in `students`.

### Nothing may wait for a face model to load

The models take minutes to load. **No route that does not need one may be blocked behind one.**

They used to be built inline in `lifespan`, which meant the server accepted *no* request at all until PyTorch, TensorFlow and a 250MB checkpoint were in memory. On a Cloud Run container that had scaled to zero, opening the roster — a plain Firestore read that touches no model whatsoever — died with `TimeoutException after 0:00:15` while queued behind machinery it never uses. It looked like the backend was down. It was starting up.

The shape now:

- `lifespan` sets up Firestore, mounts `/faces`, and returns. The API is answering in seconds.
- Models load on a background thread, **active backend first**, since attendance is what waits on it.
- `_get_db()` for database-only routes — never waits. `_get_services()` for routes that truly need recognition — returns **503 with a plain-English "still loading"** rather than hanging.
- `GET /` reports `recognition_ready` and `dual_registration_ready`, so "is it warm?" is a question you can answer.

Client timeouts must stay well above a cold start (currently 90s for reads) and treat 503 as *wait*, not *fail*.

### Cloud Run starves background threads unless you tell it not to

**The agentic scan does not work on Cloud Run without `--no-cpu-throttling`.**

By default Cloud Run gives a container CPU *only while it is handling a request* and throttles it to near zero in between. That is a sensible default for an ordinary web service and precisely wrong for this one: `/take_attendance_agentic` returns a job id in milliseconds and then does all the real work on a background thread, which is the exact case that default starves.

Observed on the first live deploy: a scan emitted its opening trace event at `0.00s` and then made no progress whatsoever for over ten minutes. It did not error and the job stayed `running` — it just stopped. Nothing in the logs said why.

Always-allocated CPU costs more per instance-second. It is not optional here. The flag is in [deploy_backend.ps1](backend/deploy_backend.ps1) with the same warning attached.

This is worth remembering as a general shape: **anything this system does after a response has been sent needs CPU that Cloud Run will not give it by default.**

### This runs on TWO Google Cloud projects, not one

Nobody wrote this down before 2026-09-08 and it is very easy to lose an evening to:

| Project | Holds |
|---|---|
| `ai-face-detector-daaad` | The **Firebase** project — Firestore (roster, attendance, face vectors) and Firebase Hosting |
| `smart-attendance-37133` | Cloud Run, Vertex AI (Gemini), the photo bucket, Secret Manager |

`backend/serviceAccountKey.json` belongs to **`ai-face-detector-daaad`**, which is the only reason Firestore works at all from a backend that otherwise lives in the other project. The key is what bridges them.

Consequences worth remembering:

- **`gcloud` defaults to the wrong project.** Always pass `--project=` explicitly. `gcloud firestore ...` against `smart-attendance-37133` will tell you the API is not enabled, which is true and completely misleading.
- **Firebase Hosting is under `ai-face-detector-daaad`**, so the app's origin is `https://ai-face-detector-daaad.web.app`. Point `ALLOWED_ORIGINS` anywhere else and every request fails a CORS check, which in a browser looks exactly like the backend being down.
- Merging the two into one project would be a real simplification. It is not a small job — Firestore cannot be moved between projects — so it is deliberately not being attempted before the expo.

### Windows gotchas that cost real time

- **TensorFlow will not load on this laptop.** `import tensorflow` fails with *"DLL load failed while importing _pywrap_tf_session: An Application Control policy has blocked this file."* That is a Windows security policy, not a Python problem, and it blocks **both** backends because RetinaFace detection is TensorFlow for both. Until it is lifted, the backend cannot start locally and face work has to happen on Cloud Run. Anything that only needs the stored vectors — `--import-legacy-index`, Firestore queries — still works, because those import neither TensorFlow nor PyTorch.
- **Never run `gcloud` from Git Bash with container paths.** Git Bash rewrites `/secrets/serviceAccountKey.json` into `C:/Program Files/Git/secrets/...` and the deploy fails with *"should be a valid unix absolute path"*. Setting `MSYS_NO_PATHCONV=1` to stop it breaks gcloud's own launcher instead. Use PowerShell — that is why the deploy script is `.ps1`.
- **Windows PowerShell 5.1 treats a native program's stderr as an error.** gcloud writes progress to stderr, so `$ErrorActionPreference = "Stop"` aborts deploys that are working fine, and `2>&1` on a gcloud call produces `NativeCommandError` even on success. Judge these commands by `$LASTEXITCODE` and do not redirect their stderr.

---

## 7. The Adjudicator — where the "agent" actually is

The recognition pipeline (detect → embed → search → threshold) always runs the same steps in the same order and answers every face with a number. That is fine when the number is decisive and useless when it is not. The Adjudicator ([services/adjudicator.py](backend/services/adjudicator.py)) handles the faces where it is not.

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
- **Two weak signals are not a match.** If the maths gave a face no support at all *and* Gemini is only medium/low confidence, the face goes to a human. Marking an absent student present is the one error nobody catches afterwards.
- **Bounded.** `ADJ_MAX_INVESTIGATIONS` faces, `ADJ_TIME_BUDGET_SECONDS` wall clock, best-scoring faces first. The budget clock starts *after* detection, because detection is work that has to happen regardless.

**The trace.** Every observation, decision and outcome is emitted through [job_store.py](backend/services/job_store.py) as it happens, with a thumbnail of the face being discussed, and rendered live by [scan_screen.dart](frontend/lib/screens/scan_screen.dart). The loop is what makes the trace honest; the trace is what makes the loop visible. They only work together.

**Deliberately not built:** trying the *other* embedding backend as an adjudication tool. Both models are now loaded (they have to be, for dual registration), so this is no longer impossible — it is simply not worth it. A second opinion from a second embedding model is still a number, and numbers are what already failed on these faces. Re-crop plus shortlist-identify is enough for the loop to visibly choose.

**Not yet measured, and it should be.** Nobody has counted how often the cheap re-crop actually settles a face versus how often it falls through to Gemini. The data is already emitted — every outcome carries `tools_used` and `resolved_by` — so counting it across a handful of scans is an hour's work and would turn "the cheap tool earns its keep" from a claim into a number. Same for CLAHE: it is applied consistently to both sides, so it is defensible, but its effect on match scores has never been A/B'd.

---

## 8. State of the codebase (audited 2026-09-08)

**Verdict: this is genuinely well-built, and well above the standard of a student project.** The things that make it good are structural, not cosmetic:

- Layers are real and respected — routes never touch storage, services never know about HTTP.
- The strategy pattern for recognition backends means adding a third model is one file.
- The job-and-poll design for the agentic scan is the *correct* answer to "this work takes longer than a request should", not a workaround.
- Failure states are three-valued (`yes` / `no` / `error`) rather than two, so a broken network never gets recorded as "that isn't them". Very few codebases at any level get this right.
- State is keyed by face position, not by student — a subtle bug avoided before it happened.
- The comments explain *why*, not *what*, and they name the failure they are preventing. This is the strongest signal in the repo.

The frontend matches: intentional design tokens with reasoning attached, a real information model behind the trace, and no templated Material defaults.

### Fixed in the 2026-09-08 pass

| # | Was | Now |
|---|---|---|
| 1 | Job store in memory vs `--max-instances=3` — a poll could hit an instance that never saw the job | `--max-instances=1` in [deploy_backend.ps1](backend/deploy_backend.ps1), with a comment saying why it is not a tuning knob. Session affinity was rejected: Cloud Run's is best-effort and would look like a fix without being one. |
| 2 | No authentication at all | One shared key on **every** request ([auth.py](backend/services/auth.py)). Implemented as middleware, not a route dependency, because `app.mount("/faces", ...)` is a separate sub-application that a dependency never runs for — that mount serves every student's photograph. Header `X-API-Key`, or `?key=` for image URLs, which an `<img>` tag needs. |
| 4 | `ArrayUnion` meant attendance could be marked but never unmarked | `log_attendance` now **replaces** the day's list, so a re-scan is a correction. The one-document-per-day limit stands and is stated in the code: a second scan overwrites the first, which is right for one class a day and wrong for two. |
| 5 | `/registration_statuses` opened FAISS's `id_map.json` files from inside the route | Asks Firestore via `get_indexed_reg_numbers()`. The HTTP layer no longer knows anything about how vectors are stored. |
| 6 | FAISS index written to a Cloud Storage FUSE mount | There is no index file at all now. Firestore holds the vectors; FAISS is rebuilt in memory at startup. |
| — | Vectors would not survive a container restart | Same change as #6, and the reason it matters more than the corruption risk did. |
| — | CORS `allow_origins=["*"]` with `allow_credentials=True` | Explicit origins from `ALLOWED_ORIGINS`; credentials off, since auth is a header not a cookie. The old pair is one browsers reject outright, so it only ever appeared to work. |
| — | Catch-all handler returned `str(exc)` to the caller | Logged server-side, generic message returned. |
| — | `azure_face.py` dead code, duplicate `import json` | Deleted. |
| — | Registering a student updated only the active backend | The server loads both backends and registers into all of them; deletion removes from all of them. No script, nothing to remember. `sync_faces.py --all-backends` remains for backfill and rebuilds. |
| — | The roster timed out on a cold container, waiting for a face model it never uses | Models load in the background; database routes answer immediately; model-dependent routes return a plain-English 503. |
| — | The agentic scan silently made no progress on Cloud Run | `--no-cpu-throttling`. Cloud Run gives no CPU to background threads by default, and our whole design does its work after the response is sent. |

### Still open

| # | Problem | Impact |
|---|---|---|
| 3 | **Zero backend tests** — deferred deliberately, not forgotten | Four functions are pure and need no server, no Firestore, no Gemini: `VLMVerificationService._parse_identification` (a malformed reply must become `error`, never `none`), `BaseFaceService.classify_score`, `AttendanceAdjudicator._shortlist`, `letterbox`. Under an hour of work, and the thing that would stop the fixes above from silently regressing. Do this before the next round of changes, not after. |
| 10 | A face whose true student is not in the FAISS shortlist can be reported "not enrolled" | The shortlist comes from vector neighbours, so if the embedding is bad enough that the right person never ranks, Gemini is never shown them. Rare, but the honest limit of the current loop. |
| 11 | No size or content-type limit on uploads | The file is read fully into memory. A large upload could exhaust the container. Low risk behind an API key; worth a `Content-Length` check before this is shown to strangers. |
| 12 | The API key is one shared secret with no rotation or per-user identity | Correct for one classroom and one demo. It is not a foundation for multiple teachers — that needs real accounts, and the roster needs a class/section concept first (see #4's note). |

### Fixed earlier (2026-08-26)

| # | Was | Now |
|---|---|---|
| 1 | `take_attendance` blocked the event loop | Runs in a worker thread. The agentic route returns a job id in milliseconds and never holds a request open at all. |
| 2 | Gemini ~14s warm / 126s cold vs a 120s client timeout | Vertex answers in ~3.5s; per-call timeouts, a startup warm-up, and job polling remove the timeout class entirely. |
| 3 | VLM only saw faces *above* `unsure_threshold` | The Adjudicator investigates the `unrecognized` tier too, and can conclude "not enrolled". |
| 4 | VLM only confirmed/denied the **top-1** guess | `identify_among_candidates()` shows a shortlist and lets Gemini name a different student. Corrections are flagged in the trace and the register. |
| 5 | `verify_match()` returned `False` on any exception | Tri-state `yes`/`no`/`error` throughout; `error` never becomes a rejection. |
| 7 | `google-generativeai` deprecated | Migrated to `google-genai` on Vertex AI. |

Old item 8 — `pubspec.yaml` saying "A new Flutter project." — is fixed as of the 2026-09-08 audit; it carries the real description now. Exactly when it was changed is not recorded, so it is not claimed under the date above.

---

## 9. Rules for not getting tangled

The biggest risk to this project is not a bug. It is spending the remaining time untangling things that were added without a decision. These rules exist to stop that.

1. **Three docs at the root, no more** (plus the one-line `AGENTS.md` pointer). CLAUDE.md, system_design.md, README.md — jobs listed at the top of this file. Before creating any new `.md` at the root, name which of the three should have held it instead. A note-to-self file becomes a stale note-to-self file within a week — `instructions.md` was deleted for exactly that reason, after spending weeks telling anyone who read it to use thresholds the code did not use.
2. **One fact, one home.** If something is true in two docs, write it in one and link from the other. Two copies drift, and the drift is invisible until it misleads you.
3. **Changes land in `base_face_service.py`.** Resist adding a new service file. A new file is justified when it owns a concern nothing else owns — not when a function got long.
4. **Two attendance routes exist on purpose. Never add a third.** Agentic for the demo, synchronous as the parachute. A third path is a third thing to keep correct.
5. **Change one layer per sitting.** Backend *or* frontend *or* the model pipeline. When something breaks after a two-layer change, you cannot tell which half did it, and that is where whole evenings go.
6. **Every new env var goes in `.env.example` the same minute**, with a comment saying what it does and why that default. Undocumented knobs are how a system becomes unexplainable to its own author.
7. **Delete dead code the day it dies.** `azure_face.py` sat unreferenced for two weeks before it went; `instructions.md` spent longer than that quietly telling readers the wrong thresholds. Dead code and stale docs both make a reader — or a judge — wonder what else is not real.
8. **Pipeline changes mean rebuild, not retune.** Touching alignment, preprocessing or model files invalidates every stored vector. Rebuild the index. Lowering thresholds to make the symptom go away hides the breakage and costs you accuracy permanently.
9. **Before starting something new, write the one-line reason it is needed.** If the line is hard to write, the thing is probably not needed. This is the cheapest filter available.
10. **Measure before optimising.** Every timing claim in §6 came from a real measurement. Keep it that way — guessed timings have already cost this project a redesign once.

---

## 10. Runbook

Everything is PowerShell, run from Windows. See §6 for why not Git Bash.

### First-time setup

```powershell
# Backend
cd "C:\workspace\AI FACE DETECTION FROM GROUP PHOTO\backend"
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
python download_model.py            # pulls the AdaFace checkpoint (~250MB)
Copy-Item .env.example .env         # then fill it in - every variable is commented

# Frontend
cd ..\frontend
flutter pub get
```

You also need `backend\serviceAccountKey.json` (Firebase service account) and,
for Gemini, `gcloud auth application-default login`.

### Day to day

```powershell
# Backend, from backend\ with the venv active
python -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload

# Frontend against the local backend, from frontend\
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000

# Frontend tests
flutter test
```

Leave `API_KEY` empty in `.env` for local work and the API is open; the startup
log says which it is, every time.

### Faces and vectors

```powershell
# Give every rostered student a vector in BOTH backends. Run this after any
# registration session - it is what makes switching backends safe.
python sync_faces.py --all-backends

# Rebuild from scratch. Required after changing alignment, preprocessing or the
# model file, because those change what a vector means. Stop the API first.
python sync_faces.py --all-backends --rebuild-local

# One-time, and only if old on-disk faiss.index files reappear from somewhere:
# copy their vectors into Firestore. Needs no face model, so it works even when
# TensorFlow will not load.
python sync_faces.py --all-backends --import-legacy-index
```

### Live URLs

| What | Where |
|---|---|
| **The app** | https://ai-face-detector-daaad.web.app |
| API | https://attendance-backend-ptpjbvdc4q-uc.a.run.app |

Open the app link on any device — nothing to install. First use asks for the
access key; the browser remembers it after that.

### Deploying

```powershell
# Backend -> Cloud Run  (~15-20 min: the image carries TensorFlow and PyTorch)
cd backend
.\deploy_backend.ps1

# Frontend -> Firebase Hosting  (~1 min)
cd frontend
flutter build web --release --dart-define=API_BASE_URL=https://attendance-backend-ptpjbvdc4q-uc.a.run.app
cd ..
$env:GOOGLE_APPLICATION_CREDENTIALS = "$PWD\backend\serviceAccountKey.json"
firebase deploy --only hosting --project ai-face-detector-daaad

# Read the access key back when you need to type it into the app
gcloud secrets versions access latest --secret=attendance-api-key --project=smart-attendance-37133
```

`firebase` authenticates with the same service account key the backend uses —
no `firebase login`, no browser. Note the two different `--project` values;
they are not a typo, see §6.

The access key is deliberately **not** baked into the web build. Anyone can
read a web page's source, so a key in there is not a key. It is typed once into
Settings and kept in the browser; the home screen says so plainly until it is
set, rather than letting the first tap fail with a bare 401.

### Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Everyone reads Absent after a model or alignment change | The stored vectors no longer mean what the model produces. Rebuild — do not lower thresholds. |
| `401` from every call | The app's key does not match the server's. Settings → Access key, or check `API_KEY` on Cloud Run. |
| Face thumbnails are blank but names load | The `?key=` on image URLs is missing or wrong — see `ApiService.faceImageUrl`. |
| A student is always absent in one backend only | They have no vector there. `python sync_faces.py --all-backends`. |
| First scan after a quiet period takes minutes | Cloud Run scaled to zero and is reloading the models. Expected — see §8 and the note in the deploy script. |
| `import tensorflow` fails on this laptop | A Windows Application Control policy, not a code problem. See §6. |
| Gemini stops answering | Check credentials before touching code: `gcloud auth application-default print-access-token \| Out-Null; $?` |

---

## 11. Safety and data

- `backend/.env` and `backend/serviceAccountKey.json` hold live secrets. Both are gitignored. **Never** print, commit, or paste their contents.
- `known_faces/` holds photographs of real students. Gitignored. The Adjudicator uploads face crops **and registration photos** to Google when it asks for a second opinion — that is a deliberate design choice and should be disclosed in the expo demo.
- Gemini runs on GCP project `smart-attendance-37133` via Application Default Credentials. If `VERTEX_PROJECT` is ever unset, the service silently falls back to the throttled AI Studio free tier rather than failing — check the startup log line, which names the transport in use.
- **The current key is a memorable demo placeholder, not a secret.** It was set deliberately so it is easy to type at the expo. It is short and guessable, and it guards a public URL holding real students' photographs. **Rotate it to a random value before this is used for anything beyond the demo** — two commands, no rebuild:
  ```powershell
  python -c "import secrets,sys; sys.stdout.buffer.write(secrets.token_urlsafe(32).encode())" > key.bin
  gcloud secrets versions add attendance-api-key --project=smart-attendance-37133 --data-file=key.bin
  gcloud run services update attendance-backend --project=smart-attendance-37133 --region=us-central1 --quiet
  ```
  Write it with **no trailing newline** — see §6 for what a stray carriage return does.
- **The API is protected by one shared key**, checked on every request including the `/faces` photo mount. It lives in Secret Manager as `attendance-api-key` and is injected into Cloud Run as `API_KEY`. Never commit it, never bake it into the web build, never paste it into a chat or an issue. If it leaks, replace it: add a new secret version and redeploy.
- **Leaving `API_KEY` empty makes the API open.** That is intended for local development and the startup log says so in capitals. It must never be the state of anything with a public URL.
- **The deployed service is `--allow-unauthenticated` at the Cloud Run level.** That is not an oversight: the browser app cannot present Google IAM credentials, so the door is our own key instead. Cloud Run lets the request through; `auth.py` decides.
- **Vectors are not photographs, but they are still biometric data.** Firestore now holds a mathematical description of each student's face. Treat that collection with the same care as `known_faces/`.
