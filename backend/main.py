import os

# Fix for OpenMP conflict between PyTorch and TensorFlow on Windows
os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"

import asyncio
import json
import threading
from contextlib import asynccontextmanager
from typing import Any

from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from services.base_face_service import BaseFaceService
from services.firebase_db import FirebaseDBService
from services.job_store import AttendanceJobStore

load_dotenv()

firebase_service: FirebaseDBService | None = None
face_service: BaseFaceService | None = None
job_store = AttendanceJobStore()


@asynccontextmanager
async def lifespan(app: FastAPI):
    global firebase_service, face_service

    credentials_path = os.getenv("FIREBASE_CREDENTIALS_PATH")
    if not credentials_path:
        raise RuntimeError("FIREBASE_CREDENTIALS_PATH is required (path to service account JSON).")

    if not os.path.exists(credentials_path):
        raise RuntimeError(f"Firebase credentials file not found: {credentials_path}")

    known_faces_dir = os.getenv("KNOWN_FACES_DIR", "known_faces")
    os.makedirs(known_faces_dir, exist_ok=True)
    firebase_service = FirebaseDBService(credentials_path=credentials_path)

    # Select face recognition backend based on environment variable
    backend = os.getenv("FACE_RECOGNITION_BACKEND", "arcface").lower().strip()
    if backend == "adaface":
        from services.adaface_service import AdaFaceService
        face_service = AdaFaceService(known_faces_dir=known_faces_dir)
    else:
        from services.deepface_service import DeepFaceService
        face_service = DeepFaceService(known_faces_dir=known_faces_dir)

    # Serve face images so the frontend can display them
    app.mount("/faces", StaticFiles(directory=known_faces_dir), name="faces")

    # Pay the one-off costs now, in the background, instead of on the first
    # scan somebody is watching. Startup is not blocked and neither failure
    # stops the server: both are optimisations, not requirements.
    def _warm_up():
        try:
            firebase_service.get_all_students()
            print("[OK] Firestore connection warmed up.")
        except Exception as e:
            print(f"[WARN] Firestore warm-up failed (first request will be slower): {e}")
        face_service.warm_up()

    threading.Thread(target=_warm_up, name="warm-up", daemon=True).start()

    yield


app = FastAPI(title="AI Attendance System API", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
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
    return _json_error(500, "INTERNAL_ERROR", "Unexpected server error.", str(exc))


def _get_services() -> tuple[FirebaseDBService, BaseFaceService]:
    if firebase_service is None or face_service is None:
        raise HTTPException(status_code=503, detail="Services are not initialized.")
    return firebase_service, face_service


@app.get("/")
def read_root():
    backend = os.getenv("FACE_RECOGNITION_BACKEND", "arcface").lower()
    return {"status": "success", "message": f"Attendance backend is running (FAISS + {backend.upper()} mode)."}


@app.post("/register_student")
async def register_student(
    name: str = Form(...),
    reg_number: str = Form(...),
    file: UploadFile = File(...),
):
    fb_service, df_service = _get_services()

    image_bytes = await file.read()
    if not image_bytes:
        raise ValueError("Uploaded file is empty.")

    # Save image + queue embedding extraction in background (non-blocking)
    df_service.register_face(reg_number=reg_number, image_bytes=image_bytes)
    fb_service.add_student(
        name=name,
        reg_number=reg_number,
        face_id=reg_number,
    )

    return {
        "status": "queued",
        "message": f"Registered {name} ({reg_number}). Face processing queued.",
    }


@app.get("/registration_status/{reg_number}")
def get_registration_status(reg_number: str):
    """Check if a student's face embedding has been processed."""
    _, df_service = _get_services()
    status_info = df_service.get_registration_status(reg_number)
    return {
        "status": "success",
        "reg_number": reg_number,
        "registration": status_info,
    }


import json

@app.get("/registration_statuses")
def get_all_registration_statuses():
    """Get processing statuses for all students (bulk polling)."""
    _, df_service = _get_services()
    active_queue = df_service.get_all_registration_statuses()
    
    known_faces_dir = os.getenv("KNOWN_FACES_DIR", "known_faces")
    
    arcface_registered = set()
    arcface_map_path = os.path.join(known_faces_dir, "arcface", "id_map.json")
    if os.path.exists(arcface_map_path):
        try:
            with open(arcface_map_path, "r") as f:
                arcface_registered = set(json.load(f).values())
        except Exception:
            pass

    adaface_registered = set()
    adaface_map_path = os.path.join(known_faces_dir, "adaface", "id_map.json")
    if os.path.exists(adaface_map_path):
        try:
            with open(adaface_map_path, "r") as f:
                adaface_registered = set(json.load(f).values())
        except Exception:
            pass

    return {
        "status": "success",
        "active_queue": active_queue,
        "arcface_registered": list(arcface_registered),
        "adaface_registered": list(adaface_registered),
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


@app.get("/students")
def get_students():
    fb_service, _ = _get_services()
    students = fb_service.get_all_students()
    return {
        "status": "success",
        "students": students,
    }


@app.delete("/students/{reg_number}")
def delete_student(reg_number: str):
    fb_service, df_service = _get_services()

    fb_service.delete_student(reg_number=reg_number)
    df_service.delete_face(reg_number=reg_number)

    return {
        "status": "success",
        "message": f"Student {reg_number} deleted.",
    }
