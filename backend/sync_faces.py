"""
Fill in or rebuild the face vectors a recognition backend needs.

Two jobs, and they are not the same one:

- **sync** — work out who is on the roster but has no vector yet, and make one.
  Cheap, safe, and what you run after adding students or switching backends.
- **rebuild** (`--rebuild-local`) — throw every vector away and make them all
  again from the registration photos. Required after any change to alignment,
  preprocessing, or the model file itself, because those change what a vector
  *means* and old ones become quietly wrong.

Either can run against one backend or `--all-backends`. That last one is the
answer to the oldest trap in this project: registering a student only ever
updated whichever backend was active, so flipping `FACE_RECOGNITION_BACKEND`
would silently make some students unrecognisable. Running both here means a
switch is just a restart.
"""

import os

# ArcFace runs on TensorFlow and AdaFace on PyTorch. With --all-backends both
# are loaded in one process, and on Windows they fight over libiomp5md.dll and
# kill the process with no error. Same fix as main.py, and for the same reason
# it must come before any other import.
os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"

import argparse

from dotenv import load_dotenv

load_dotenv()

BACKENDS = ("arcface", "adaface")


def _create_face_service(backend: str, known_faces_dir: str, db):
    """Build one recognition backend by name, without starting FastAPI."""
    if backend == "adaface":
        from services.adaface_service import AdaFaceService

        return AdaFaceService(known_faces_dir=known_faces_dir, db=db)

    from services.deepface_service import DeepFaceService

    return DeepFaceService(known_faces_dir=known_faces_dir, db=db)


def _active_backend() -> str:
    return os.getenv("FACE_RECOGNITION_BACKEND", "arcface").lower().strip()


def _local_images(known_faces_dir: str) -> list[str]:
    return sorted(
        (
            os.path.join(known_faces_dir, name)
            for name in os.listdir(known_faces_dir)
            if name.lower().endswith((".jpg", ".jpeg", ".png"))
        ),
        key=lambda path: os.path.basename(path).lower(),
    )


def _drain(face_service) -> tuple[int, dict]:
    """Wait for the background registration queue, then report what happened."""
    face_service._executor.shutdown(wait=True)
    statuses = face_service.get_all_registration_statuses()
    completed = sum(info["status"] == "completed" for info in statuses.values())
    failed = {
        reg_number: info.get("error")
        for reg_number, info in statuses.items()
        if info["status"] != "completed"
    }
    return completed, failed


def rebuild_local_index(face_service) -> bool:
    """
    Recreate one backend's vectors from the local registration images.

    Deliberately does not consult Firebase: it rebuilds exactly what there are
    photographs for, which also drops any orphaned identity that exists only in
    the index. Stop the API before running this so nothing searches an index
    that is halfway through being replaced.
    """
    image_paths = _local_images(face_service.known_faces_dir)
    if not image_paths:
        raise RuntimeError("No local registration images found to rebuild the index.")

    print(
        f"[INFO] Rebuilding {face_service.backend_name} vectors from "
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

    completed, failed = _drain(face_service)
    print(f"[INFO] {face_service.backend_name}: rebuild complete — {completed} done, {len(failed)} failed.")
    if failed:
        print(f"[WARN] Failed registrations: {failed}")
    return not failed


def sync_backend(face_service, students) -> bool:
    """Give a vector to every rostered student who does not have one yet."""
    name = face_service.backend_name
    indexed = set(face_service._id_map.values())
    print(f"[INFO] {name}: {len(indexed)} of {len(students)} students already have a vector.")

    queued = 0
    missing_images = []
    for student in students:
        reg_number = student["reg_number"]
        if reg_number in indexed:
            continue
        img_path = os.path.join(face_service.known_faces_dir, f"{reg_number}.jpg")
        if not os.path.exists(img_path):
            missing_images.append(reg_number)
            continue
        print(f"[*] {name}: missing {reg_number}, queueing embedding extraction...")
        with open(img_path, "rb") as image_file:
            face_service.register_face(reg_number, image_file.read())
        queued += 1

    if missing_images:
        print(f"[WARN] {name}: no registration photo on disk for {missing_images} — cannot enrol them.")

    if not queued:
        print(f"[INFO] {name}: already up to date.")
        return not missing_images

    print(f"[INFO] {name}: waiting for {queued} face(s) to be processed...")
    completed, failed = _drain(face_service)
    print(f"[INFO] {name}: {completed} synced, {len(failed)} failed.")
    if failed:
        print(f"[WARN] Failed registrations: {failed}")
    return not failed and not missing_images


def import_legacy_index(db, known_faces_dir: str, backend: str) -> bool:
    """
    Move vectors out of an old on-disk `faiss.index` and into Firestore.

    One-time migration, kept because it is the only path that needs neither the
    face models nor the photographs: the vectors already exist, they are just in
    the wrong place. Re-running it is harmless — each student's document is
    overwritten with the same numbers.

    Deliberately imports nothing from `services.*face*`, so it works on a
    machine where TensorFlow or PyTorch cannot load.
    """
    import faiss
    import json

    index_dir = os.path.join(known_faces_dir, backend)
    index_path = os.path.join(index_dir, "faiss.index")
    map_path = os.path.join(index_dir, "id_map.json")

    if not (os.path.exists(index_path) and os.path.exists(map_path)):
        print(f"[INFO] {backend}: no legacy index at {index_dir}/ — nothing to import.")
        return True

    index = faiss.read_index(index_path)
    with open(map_path, "r") as f:
        id_map = {int(k): v for k, v in json.load(f).items()}

    # An IndexIDMap stores vectors in its own order and keeps the caller's ids
    # alongside. Walk the storage order and look each id up, rather than
    # assuming position == id.
    faiss_ids = faiss.vector_to_array(index.id_map)
    underlying = faiss.downcast_index(index.index)

    imported, skipped = 0, []
    for position, faiss_id in enumerate(faiss_ids):
        reg_number = id_map.get(int(faiss_id))
        if reg_number is None:
            skipped.append(int(faiss_id))
            continue
        vector = underlying.reconstruct(int(position))
        db.save_embedding(backend, reg_number, vector.tolist())
        imported += 1

    print(f"[OK] {backend}: imported {imported} vector(s) into Firestore.")
    if skipped:
        print(f"[WARN] {backend}: {len(skipped)} index id(s) had no name and were skipped: {skipped}")
    return True


def main():
    parser = argparse.ArgumentParser(description="Sync or rebuild face embeddings.")
    parser.add_argument(
        "--rebuild-local",
        action="store_true",
        help="discard existing vectors and rebuild them from local face images",
    )
    parser.add_argument(
        "--all-backends",
        action="store_true",
        help="apply to BOTH arcface and adaface, so switching backends needs no re-registration",
    )
    parser.add_argument(
        "--backend",
        choices=BACKENDS,
        help="apply to this backend only (default: whichever FACE_RECOGNITION_BACKEND names)",
    )
    parser.add_argument(
        "--import-legacy-index",
        action="store_true",
        help="one-time: copy vectors from old on-disk faiss.index files into Firestore "
        "(needs no face model, so it works where TensorFlow cannot load)",
    )
    args = parser.parse_args()

    if args.all_backends and args.backend:
        parser.error("--all-backends and --backend are mutually exclusive.")

    known_faces_dir = os.getenv("KNOWN_FACES_DIR", "known_faces")
    credentials_path = os.getenv("FIREBASE_CREDENTIALS_PATH")
    if not credentials_path:
        raise SystemExit("FIREBASE_CREDENTIALS_PATH is required (path to service account JSON).")

    from services.firebase_db import FirebaseDBService

    db = FirebaseDBService(credentials_path=credentials_path)

    targets = list(BACKENDS) if args.all_backends else [args.backend or _active_backend()]
    print(f"[INFO] Target backend(s): {', '.join(targets)}")

    # The legacy import touches neither the models nor the photos, so it runs
    # before anything heavy is imported and exits on its own.
    if args.import_legacy_index:
        ok = True
        for backend in targets:
            print(f"\n{'=' * 60}\n  {backend.upper()}  (legacy index import)\n{'=' * 60}")
            ok = import_legacy_index(db, known_faces_dir, backend) and ok
        print("\n[DONE] Legacy vectors imported." if ok else "\n[DONE] Finished with problems.")
        if not ok:
            raise SystemExit(1)
        return

    students = [] if args.rebuild_local else db.get_all_students()
    if not args.rebuild_local:
        print(f"[INFO] Found {len(students)} students in Firestore.")

    ok = True
    for backend in targets:
        print(f"\n{'=' * 60}\n  {backend.upper()}\n{'=' * 60}")
        face_service = _create_face_service(backend, known_faces_dir, db)
        if args.rebuild_local:
            ok = rebuild_local_index(face_service) and ok
        else:
            ok = sync_backend(face_service, students) and ok

    print("\n[DONE] All requested backends processed." if ok else "\n[DONE] Finished with problems — see warnings above.")
    if not ok:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
