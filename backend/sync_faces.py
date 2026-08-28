import argparse
import os

from dotenv import load_dotenv

load_dotenv()


def _create_face_service(known_faces_dir: str):
    """Create the backend selected in .env without starting FastAPI."""
    backend = os.getenv("FACE_RECOGNITION_BACKEND", "arcface").lower().strip()
    if backend == "adaface":
        from services.adaface_service import AdaFaceService

        return AdaFaceService(known_faces_dir=known_faces_dir)

    from services.deepface_service import DeepFaceService

    return DeepFaceService(known_faces_dir=known_faces_dir)


def rebuild_local_index(face_service) -> bool:
    """Recreate the selected backend index from local registration images.

    This intentionally avoids Firebase and excludes index-only/orphaned IDs.
    Stop the API before running it so no process searches or writes the same
    index while the rebuild is in progress.
    """
    image_paths = sorted(
        (
            os.path.join(face_service.known_faces_dir, name)
            for name in os.listdir(face_service.known_faces_dir)
            if name.lower().endswith((".jpg", ".jpeg", ".png"))
        ),
        key=lambda path: os.path.basename(path).lower(),
    )
    if not image_paths:
        raise RuntimeError("No local registration images found to rebuild the index.")

    print(
        f"[INFO] Rebuilding {face_service.backend_name} index from "
        f"{len(image_paths)} local image(s)..."
    )
    face_service.reset_index()

    for image_path in image_paths:
        reg_number = os.path.splitext(os.path.basename(image_path))[0]
        with open(image_path, "rb") as image_file:
            face_service.register_face(
                reg_number,
                image_file.read(),
                cleanup_image_on_failure=False,
            )

    face_service._executor.shutdown(wait=True)
    statuses = face_service.get_all_registration_statuses()
    completed = sum(info["status"] == "completed" for info in statuses.values())
    failed = {
        reg_number: info.get("error")
        for reg_number, info in statuses.items()
        if info["status"] != "completed"
    }
    print(f"[INFO] Rebuild complete: {completed} completed, {len(failed)} failed.")
    if failed:
        print(f"[WARN] Failed registrations: {failed}")
    return not failed


def sync_faces():
    print("[INFO] Starting Face Sync...")

    credentials_path = os.getenv("FIREBASE_CREDENTIALS_PATH")
    known_faces_dir = os.getenv("KNOWN_FACES_DIR", "known_faces")

    from services.firebase_db import FirebaseDBService

    fb_service = FirebaseDBService(credentials_path=credentials_path)
    face_service = _create_face_service(known_faces_dir)

    # 1. Get all students from Firebase
    students = fb_service.get_all_students()
    print(f"[INFO] Found {len(students)} students in Firebase.")

    # 2. Get all students currently in FAISS index
    indexed_reg_numbers = set(face_service._id_map.values())
    print(
        f"[INFO] Found {len(indexed_reg_numbers)} students in FAISS "
        f"({face_service.backend_name})."
    )

    # 3. Find missing students
    queued_count = 0
    for student in students:
        reg_number = student["reg_number"]
        if reg_number not in indexed_reg_numbers:
            img_path = os.path.join(face_service.known_faces_dir, f"{reg_number}.jpg")
            if os.path.exists(img_path):
                print(f"[*] Missing in FAISS: {reg_number}. Queueing for embedding extraction...")
                with open(img_path, "rb") as image_file:
                    face_service.register_face(reg_number, image_file.read())
                queued_count += 1
            else:
                print(f"[WARN] Missing image file for {reg_number}: {img_path}")

    print(f"[INFO] Queued {queued_count} students for background processing.")
    if queued_count > 0:
        print("[INFO] Waiting for all faces to be processed...")
        face_service._executor.shutdown(wait=True)
        print("[INFO] Done! All missing faces have been synced to the new FAISS index.")
    else:
        print("[INFO] Everything is already up-to-date.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Sync or rebuild local face embeddings.")
    parser.add_argument(
        "--rebuild-local",
        action="store_true",
        help="rebuild the selected backend index from local face images only",
    )
    args = parser.parse_args()

    if args.rebuild_local:
        face_service = _create_face_service(os.getenv("KNOWN_FACES_DIR", "known_faces"))
        if not rebuild_local_index(face_service):
            raise SystemExit(1)
    else:
        sync_faces()