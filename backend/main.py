import os

# Fix for OpenMP conflict between PyTorch and TensorFlow on Windows
os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"

import asyncio
import threading
from contextlib import asynccontextmanager
from typing import Any

from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from services import auth
from services.base_face_service import BaseFaceService
from services.firebase_db import FirebaseDBService
from services.job_store import AttendanceJobStore

load_dotenv()

firebase_service: FirebaseDBService | None = None

# Every recognition backend that finished loading, keyed by name. The active
# one answers attendance; *all* of them receive registrations, which is what
# stops a student from being invisible after a backend switch.
face_services: dict[str, BaseFaceService] = {}
ACTIVE_BACKEND = os.getenv("FACE_RECOGNITION_BACKEND", "arcface").lower().strip()
ALL_BACKENDS = ("arcface", "adaface")

job_store = AttendanceJobStore()


def _build_backend(name: str, known_faces_dir: str) -> BaseFaceService:
    """Import and construct one recognition backend. Slow: this loads a model."""
    if name == "adaface":
        from services.adaface_service import AdaFaceService

        return AdaFaceService(known_faces_dir=known_faces_dir, db=firebase_service)

    from services.deepface_service import DeepFaceService

    return DeepFaceService(known_faces_dir=known_faces_dir, db=firebase_service)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global firebase_service

    credentials_path = os.getenv("FIREBASE_CREDENTIALS_PATH")
    if not credentials_path:
        raise RuntimeError("FIREBASE_CREDENTIALS_PATH is required (path to service account JSON).")

    if not os.path.exists(credentials_path):
        raise RuntimeError(f"Firebase credentials file not found: {credentials_path}")

    known_faces_dir = os.getenv("KNOWN_FACES_DIR", "known_faces")
    os.makedirs(known_faces_dir, exist_ok=True)
    firebase_service = FirebaseDBService(credentials_path=credentials_path)

    print(auth.describe_state())

    # Serve face images so the frontend can display them
    app.mount("/faces", StaticFiles(directory=known_faces_dir), name="faces")

    # Loading the face models takes minutes, and NOTHING else may wait for it.
    #
    # This used to happen right here, inline, which meant the server accepted
    # no requests at all until PyTorch, TensorFlow and a 250MB checkpoint were
    # in memory. On Cloud Run, where the container sleeps when idle, that made
    # the roster — a plain database read that needs no model whatsoever — fail
    # with a client-side timeout while it waited for machinery it never uses.
    #
    # So the models load on a background thread and the API is up immediately.
    # Routes that need a model say so honestly (503) until it arrives; routes
    # that only need Firestore answer straight away.
    def _boot():
        try:
            firebase_service.get_all_students()
            print("[OK] Firestore connection warmed up.")
        except Exception as e:
            print(f"[WARN] Firestore warm-up failed (first request will be slower): {e}")

        # Active backend first — attendance is blocked until it exists, so it
        # is the one worth having soonest.
        ordered = [ACTIVE_BACKEND] + [b for b in ALL_BACKENDS if b != ACTIVE_BACKEND]
        for name in ordered:
            try:
                face_services[name] = _build_backend(name, known_faces_dir)
                print(f"[OK] {name.upper()} backend ready.")
                if name == ACTIVE_BACKEND:
                    face_services[name].warm_up()
            except Exception as e:
                # A secondary backend that will not load costs dual
                # registration, not the demo. Say so and carry on.
                print(f"[WARN] Could not load {name} backend: {e}")

        print(f"[OK] Startup complete. Backends loaded: {sorted(face_services)} | active: {ACTIVE_BACKEND}")

    threading.Thread(target=_boot, name="boot", daemon=True).start()

    yield


app = FastAPI(title="AI Attendance System API", lifespan=lifespan)

# Every request passes the shared-key check, including the /faces mount that
# serves students' photographs. See services/auth.py for why this is
# middleware rather than a route dependency.
app.middleware("http")(auth.api_key_middleware)

# Which websites are allowed to call this API from a browser.
#
# `["*"]` is right while everything is on localhost and wrong once the Flutter
# web build is hosted somewhere real: list that origin instead. Note the old
# combination here — `allow_origins=["*"]` together with
# `allow_credentials=True` — is one browsers reject outright, so it only ever
# appeared to work. Credentials are off because this API authenticates with a
# header, not a cookie.
_origins = [o.strip() for o in os.getenv("ALLOWED_ORIGINS", "*").split(",") if o.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_origins,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


def _json_error(status_code: int, code: str, message: str, details: Any = None) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content={
            "status": "error",
            "error": {
                "code": code,
                "message": message,
                "details": details,
            },
        },
    )


@app.exception_handler(ValueError)
async def value_error_handler(_, exc: ValueError):
    return _json_error(400, "VALIDATION_ERROR", str(exc))


@app.exception_handler(HTTPException)
async def http_exception_handler(_: Request, exc: HTTPException):
    message = exc.detail if isinstance(exc.detail, str) else "Request failed."
    return _json_error(exc.status_code, "HTTP_ERROR", message, exc.detail)


@app.exception_handler(Exception)
async def unhandled_exception_handler(_, exc: Exception):
    # The detail goes to the server log, not to the caller. An unexpected
    # exception's text routinely contains file paths, credential names and
    # library internals, and the client can do nothing useful with any of it.
    print(f"[ERROR] Unhandled exception: {type(exc).__name__}: {exc}")
    return _json_error(500, "INTERNAL_ERROR", "Unexpected server error.")


_STILL_LOADING = (
    "The face recognition model is still loading. This takes a minute or two after "
    "the server has been idle. The roster works already - try this again shortly."
)


def _get_db() -> FirebaseDBService:
    """For routes that only read or write the database. Never waits for a model."""
    if firebase_service is None:
        raise HTTPException(status_code=503, detail="Server is still starting.")
    return firebase_service


def _get_services() -> tuple[FirebaseDBService, BaseFaceService]:
    """For routes that genuinely need the active recognition backend."""
    db = _get_db()
    active = face_services.get(ACTIVE_BACKEND)
    if active is None:
        raise HTTPException(status_code=503, detail=_STILL_LOADING)
    return db, active


def _get_all_backends() -> list[BaseFaceService]:
    """
    Every loaded backend, active one first.

    Registration and deletion go through here rather than through the active
    backend alone. That is the whole point: a student registered today must
    still be recognisable if `FACE_RECOGNITION_BACKEND` is flipped tomorrow.
    """
    active = face_services.get(ACTIVE_BACKEND)
    if active is None:
        raise HTTPException(status_code=503, detail=_STILL_LOADING)
    return [active] + [s for n, s in face_services.items() if n != ACTIVE_BACKEND]


@app.get("/")
def read_root():
    """Also the readiness probe, so it must never depend on a model."""
    ready = sorted(face_services)
    return {
        "status": "success",
        "message": f"Attendance backend is running (active: {ACTIVE_BACKEND.upper()}).",
        "active_backend": ACTIVE_BACKEND,
        "backends_loaded": ready,
        "recognition_ready": ACTIVE_BACKEND in face_services,
        "dual_registration_ready": len(ready) == len(ALL_BACKENDS),
    }


@app.post("/register_student")
async def register_student(
    name: str = Form(...),
    reg_number: str = Form(...),
    file: UploadFile = File(...),
):
    fb_service = _get_db()
    backends = _get_all_backends()

    image_bytes = await file.read()
    if not image_bytes:
        raise ValueError("Uploaded file is empty.")

    # Register into EVERY loaded backend, not just the active one.
    #
    # This used to touch only the active backend, so switching
    # FACE_RECOGNITION_BACKEND left some students with no vector in the new one
    # — and they were then silently marked absent by a system that looked like
    # it was working. Fixing that needed a script somebody had to remember to
    # run. Now it just happens.
    #
    # The photograph is shared, so only the first backend writes it, and no
    # backend deletes it on failure: one model failing to find a face must not
    # destroy the image the other one succeeded with.
    for index, service in enumerate(backends):
        service.register_face(
            reg_number=reg_number,
            image_bytes=image_bytes,
            save_image=(index == 0),
            cleanup_image_on_failure=False,
        )

    fb_service.add_student(
        name=name,
        reg_number=reg_number,
        face_id=reg_number,
    )

    names = [s.backend_name for s in backends]
    return {
        "status": "queued",
        "message": f"Registered {name} ({reg_number}). Face processing queued for {', '.join(names)}.",
        "backends": names,
    }


@app.get("/registration_status/{reg_number}")
def get_registration_status(reg_number: str):
    """Check if a student's face embedding has been processed."""
    active = face_services.get(ACTIVE_BACKEND)
    status_info = (
        active.get_registration_status(reg_number)
        if active
        else {"status": "unknown", "error": None}
    )
    return {
        "status": "success",
        "reg_number": reg_number,
        "registration": status_info,
    }


@app.get("/registration_statuses")
def get_all_registration_statuses():
    """
    Which students have a usable face vector, per recognition backend.

    This used to open FAISS's `id_map.json` files off disk from inside the
    route, which meant the HTTP layer knew the private file layout of the
    storage layer — change how vectors are stored and this endpoint silently
    returned empty lists. It now asks the database, which is the thing that
    actually knows.
    """
    fb_service = _get_db()

    # Merge the in-flight queues of whichever backends have loaded. If none
    # have yet, the stored lists below still answer the question the screen is
    # actually asking, so this route never waits for a model.
    active_queue: dict = {}
    for service in face_services.values():
        active_queue.update(service.get_all_registration_statuses())

    return {
        "status": "success",
        "active_queue": active_queue,
        "arcface_registered": fb_service.get_indexed_reg_numbers("arcface"),
        "adaface_registered": fb_service.get_indexed_reg_numbers("adaface"),
    }


@app.post("/take_attendance")
async def take_attendance(file: UploadFile = File(...)):
    fb_service, df_service = _get_services()

    image_bytes = await file.read()
    if not image_bytes:
        raise ValueError("Uploaded file is empty.")

    # Firestore's client is synchronous, so this is a blocking network call —
    # it belongs in a worker thread for the same reason the scan itself does.
    all_students = await asyncio.to_thread(fb_service.get_all_students)
    if not all_students:
        raise HTTPException(
            status_code=400,
            detail="No students registered yet. Register at least one student first.",
        )

    # take_attendance() is CPU-heavy (face detection/embedding) and can also
    # make blocking Gemini network calls for unsure faces. Running it inline
    # would freeze the asyncio event loop — blocking /students, health
    # checks, and every other request until the scan finishes. Running it in
    # a worker thread keeps the API responsive during a scan.
    attendance_result = await asyncio.to_thread(
        df_service.take_attendance,
        image_bytes=image_bytes,
        all_students=all_students,
    )

    present_reg_numbers = attendance_result.get("recognized_reg_numbers", [])
    if present_reg_numbers:
        fb_service.log_attendance(present_reg_numbers=present_reg_numbers)

    return {
        "status": "success",
        "present": attendance_result["present"],
        "absent": attendance_result["absent"],
        "unsure": attendance_result["unsure"],
        "processing": attendance_result["processing"],
        "recognized_count": attendance_result["recognized_count"],
        "unsure_count": attendance_result["unsure_count"],
    }


@app.post("/take_attendance_agentic")
async def take_attendance_agentic(file: UploadFile = File(...)):
    """
    Start an adjudicated attendance scan and return immediately.

    Unlike /take_attendance, this does not hold the request open for the whole
    scan. It returns a job id straight away; the client then polls
    /attendance_job/{job_id} to watch the reasoning as it happens and to collect
    the final result. Because no request is waiting, a slow investigation can
    never trip the client's request timeout.

    /take_attendance is still there and unchanged — if anything here misbehaves
    mid-demo, the original synchronous path is one call away.
    """
    fb_service, df_service = _get_services()

    image_bytes = await file.read()
    if not image_bytes:
        raise ValueError("Uploaded file is empty.")

    # Blocking Firestore call — keep it off the event loop so this route
    # really does return in milliseconds.
    all_students = await asyncio.to_thread(fb_service.get_all_students)
    if not all_students:
        raise HTTPException(
            status_code=400,
            detail="No students registered yet. Register at least one student first.",
        )

    job_id = job_store.create()

    def run_scan():
        try:
            result = df_service.take_attendance_agentic(
                image_bytes=image_bytes,
                all_students=all_students,
                emit=lambda event: job_store.append_event(job_id, event),
            )
            present_reg_numbers = result.get("recognized_reg_numbers", [])
            if present_reg_numbers:
                fb_service.log_attendance(present_reg_numbers=present_reg_numbers)
            job_store.finish(job_id, result)
        except Exception as e:
            print(f"[ERROR] Agentic attendance job {job_id} failed: {e}")
            job_store.fail(job_id, str(e))

    threading.Thread(target=run_scan, name=f"attendance-{job_id}", daemon=True).start()

    return {"status": "started", "job_id": job_id}


@app.get("/attendance_job/{job_id}")
def get_attendance_job(job_id: str, since: int = 0):
    """
    Fetch everything that has happened on a scan since event number `since`.

    Poll this until `status` is no longer "running"; `result` is populated when
    it reaches "done". Pass back the `cursor` from the previous response as
    `since` so each event, and each face thumbnail, is sent exactly once.
    """
    snapshot = job_store.snapshot(job_id, since=since)
    if snapshot is None:
        raise HTTPException(status_code=404, detail="Unknown or expired attendance job.")

    # `status` is this API's success/error convention throughout, so the job's
    # own lifecycle state gets its own key rather than shadowing it.
    return {
        "status": "success",
        "job_id": snapshot["job_id"],
        "job_status": snapshot["status"],
        "events": snapshot["events"],
        "cursor": snapshot["cursor"],
        "result": snapshot["result"],
        "error": snapshot["error"],
    }


@app.post("/attendance/confirm")
async def confirm_attendance(payload: dict):
    """
    Record the register the teacher signed off.

    A scan proposes; a person decides. This is the endpoint that separates the
    two — everything before it is the system's opinion, and only this is the
    record. Needs no face model, so it works while one is still loading.

    Body: {"present": ["1", "3", ...], "date": "YYYY-MM-DD" (optional)}
    """
    fb_service = _get_db()

    present = payload.get("present")
    if not isinstance(present, list) or any(not isinstance(r, str) for r in present):
        raise ValueError("'present' must be a list of registration numbers.")

    date = payload.get("date")
    if date is not None and not isinstance(date, str):
        raise ValueError("'date' must be a string like 2026-09-08.")

    # Only real students can be marked present. A stale reg number from an old
    # screen would otherwise be written into the register unchallenged.
    roster = {s["reg_number"] for s in fb_service.get_all_students()}
    unknown = sorted(set(present) - roster)
    if unknown:
        raise ValueError(f"Not on the roster: {', '.join(unknown)}")

    result = fb_service.confirm_attendance(present_reg_numbers=present, date=date)
    return {"status": "success", **result, "confirmed_by_teacher": True}


@app.get("/attendance")
def get_attendance(date: str | None = None):
    """Read back a day's register and whether a human signed it off."""
    return {"status": "success", "attendance": _get_db().get_attendance(date)}


@app.get("/students")
def get_students():
    # Database only. This is the route that used to time out on a cold Cloud
    # Run container because it was queued behind a face model it never uses.
    fb_service = _get_db()
    students = fb_service.get_all_students()
    return {
        "status": "success",
        "students": students,
    }


@app.delete("/students/{reg_number}")
def delete_student(reg_number: str):
    fb_service = _get_db()

    # Deleting somebody must NEVER depend on a face model being loaded.
    #
    # This used to ask for the backends first and 503 if they were still
    # starting — but only *after* removing the roster row. On a container that
    # had scaled to zero that produced a half-deleted student: gone from the
    # roster, vector still in the index. Observed in the wild, on a real one.
    #
    # Everything durable here is a database row or a file. The models only hold
    # a searchable copy, so they are told afterwards, and only if they exist.
    fb_service.delete_student(reg_number=reg_number)
    fb_service.delete_all_embeddings_for_student(reg_number)

    img_path = os.path.join(
        os.getenv("KNOWN_FACES_DIR", "known_faces"), f"{reg_number}.jpg"
    )
    if os.path.exists(img_path):
        os.remove(img_path)

    # Best effort: whichever backends are in memory stop offering them as a
    # candidate. A backend still loading will not have them either, because it
    # builds its index from the vectors that were just deleted.
    for service in list(face_services.values()):
        service.forget(reg_number)

    return {
        "status": "success",
        "message": f"Student {reg_number} deleted from the roster and every recognition backend.",
    }
