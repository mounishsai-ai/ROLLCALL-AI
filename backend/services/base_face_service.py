"""
Base face service providing the shared FAISS vector search, background
registration queue, status tracking, and CLAHE preprocessing. Both ArcFace
(DeepFace) and AdaFace backends extend this class.

**Where the vectors live.** Firestore, not the filesystem. FAISS is built in
memory at startup from what Firestore holds, and every registration writes
through to Firestore as well as into the in-memory index. Nothing is persisted
to disk.

That split is deliberate. A `faiss.index` file was fine on one laptop and
became a liability the moment this ran on Cloud Run: container disks are
discarded on restart, and a Cloud Storage mount is not a safe home for a file
that gets opened, seeked and rewritten in place. Keeping the durable copy in a
database and the searchable copy in memory means FAISS does the one thing it is
excellent at and is never trusted with the one thing it is not.
"""

import os
import threading
from abc import ABC, abstractmethod
from concurrent.futures import ThreadPoolExecutor

import cv2
import faiss
import numpy as np


class BaseFaceService(ABC):
    """
    Abstract base for face recognition backends.
    Subclasses only need to implement `_extract_embeddings()`.

    Provides:
    - In-memory FAISS search, rebuilt from Firestore at startup
    - Background registration queue (ThreadPoolExecutor, single worker)
    - Thread-safe registration status tracking
    - CLAHE image preprocessing
    - Common registration / attendance / deletion flows
    """

    # ArcFace and AdaFace both produce 512-d embeddings
    EMBEDDING_DIM = 512

    def __init__(
        self,
        known_faces_dir: str,
        backend_name: str,
        match_threshold: float,
        unsure_threshold: float,
        db=None,
    ):
        self.known_faces_dir = known_faces_dir
        self.backend_name = backend_name
        self.match_threshold = match_threshold
        self.unsure_threshold = unsure_threshold
        # The durable home for this backend's vectors. Required: without it
        # every registration would be forgotten on the next restart, silently,
        # which is worse than refusing to start.
        if db is None:
            raise ValueError(
                "A FirebaseDBService is required — face embeddings are stored in Firestore."
            )
        self.db = db
        # A close runner-up is an ambiguous identity, even if the best score
        # clears the absolute threshold. Keep this configurable so it can be
        # calibrated from real classroom validation data.
        self.match_margin = float(os.getenv("FACE_MATCH_MARGIN", "0.05"))

        # Registration images are shared across backends; vectors are not.
        os.makedirs(known_faces_dir, exist_ok=True)

        # The searchable copy. Rebuilt from Firestore, never written to disk.
        self._id_map: dict[int, str] = {}  # Maps FAISS integer ID -> reg_number
        self._next_id: int = 0
        self._index_lock = threading.Lock()
        self._index = self._build_index_from_db()

        self._executor = ThreadPoolExecutor(max_workers=1)
        self._registration_status: dict[str, dict] = {}
        self._status_lock = threading.Lock()
        
        from services.vlm_service import VLMVerificationService
        self.vlm_service = VLMVerificationService()

        print(
            f"[OK] {backend_name.upper()} Service ready. "
            f"Faces dir: {known_faces_dir}/ | "
            f"Vectors: Firestore ({backend_name}) -> in-memory FAISS | "
            f"Index size: {self._index.ntotal} | "
            f"Match threshold: {self.match_threshold:.2f} | "
            f"Unsure threshold: {self.unsure_threshold:.2f} | "
            f"Required margin: {self.match_margin:.2f}"
        )

    # ──────────────────────────────────────────────
    #  Abstract: subclasses must implement this
    # ──────────────────────────────────────────────

    @abstractmethod
    def _extract_embeddings(
        self, img: np.ndarray, enforce_detection: bool = True
    ) -> list[tuple[np.ndarray, np.ndarray, dict]]:
        """
        Detect faces in `img` and return a list of (embedding, face_crop, meta).

        Args:
            img: Preprocessed BGR image (CLAHE already applied by caller).
            enforce_detection: If True, raise ValueError when no face found.

        Returns:
            List of tuples (embedding_vector, face_crop_image, meta), where
            `meta` contains at least `facial_area` ({x, y, w, h} in `img`
            coordinates) and `detector_confidence`.
        """
        ...

    # ──────────────────────────────────────────────
    #  FAISS Index Management
    # ──────────────────────────────────────────────

    def _empty_index(self) -> faiss.IndexIDMap:
        # Inner Product on L2-normalized vectors == Cosine Similarity
        return faiss.IndexIDMap(faiss.IndexFlatIP(self.EMBEDDING_DIM))

    def _build_index_from_db(self) -> faiss.IndexIDMap:
        """
        Rebuild the searchable index from the vectors Firestore is holding.

        This is the whole startup cost of the index: reading a few small
        documents. It is not re-running the face model — the vectors already
        exist, they are just being loaded into something that can search them.
        A failure here leaves an empty index rather than stopping the server,
        because a backend that answers "nobody is enrolled" is still
        diagnosable, whereas one that refuses to start is not.
        """
        index = self._empty_index()
        self._id_map = {}
        self._next_id = 0

        try:
            stored = self.db.get_embeddings(self.backend_name)
        except Exception as e:
            print(f"[WARN] Could not load {self.backend_name} embeddings from Firestore: {e}")
            return index

        vectors, ids = [], []
        for entry in stored:
            vec = np.asarray(entry["vector"], dtype=np.float32)
            if vec.size != self.EMBEDDING_DIM:
                print(
                    f"[WARN] Skipping {entry['reg_number']}: expected "
                    f"{self.EMBEDDING_DIM} dimensions, found {vec.size}."
                )
                continue
            faiss_id = self._next_id
            self._next_id += 1
            self._id_map[faiss_id] = entry["reg_number"]
            vectors.append(vec)
            ids.append(faiss_id)

        if vectors:
            matrix = np.vstack(vectors).astype(np.float32)
            # Stored vectors were normalized before saving, but normalizing
            # again is free and makes the index correct even if something ever
            # writes a raw vector.
            faiss.normalize_L2(matrix)
            index.add_with_ids(matrix, np.array(ids, dtype=np.int64))

        print(f"[OK] Built {self.backend_name} index from Firestore with {index.ntotal} vector(s).")
        return index

    def reload_index(self):
        """Re-read every vector from Firestore, discarding the in-memory copy."""
        with self._index_lock:
            self._index = self._build_index_from_db()

    def reset_index(self):
        """
        Throw away every vector this backend has, in memory and in Firestore.

        Deliberately separate from normal sync: a rebuild is required after
        changing preprocessing or alignment, whereas sync only fills in
        identities that are missing.
        """
        deleted = self.db.delete_backend_embeddings(self.backend_name)
        with self._index_lock:
            self._index = self._empty_index()
            self._id_map = {}
            self._next_id = 0
        print(f"[OK] Cleared {deleted} stored {self.backend_name} vector(s).")

    @staticmethod
    def _normalize(embedding: np.ndarray) -> np.ndarray:
        """L2-normalize a vector so that Inner Product == Cosine Similarity."""
        vec = np.array(embedding, dtype=np.float32).reshape(1, -1)
        faiss.normalize_L2(vec)
        return vec

    # ──────────────────────────────────────────────
    #  Image Preprocessing
    # ──────────────────────────────────────────────

    @staticmethod
    def _preprocess_image(img: np.ndarray) -> np.ndarray:
        """Normalize lighting using CLAHE for consistent embeddings across
        different lighting conditions (registration vs group photos)."""
        lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
        l_channel, a_channel, b_channel = cv2.split(lab)
        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        l_channel = clahe.apply(l_channel)
        lab = cv2.merge([l_channel, a_channel, b_channel])
        return cv2.cvtColor(lab, cv2.COLOR_LAB2BGR)

    # ──────────────────────────────────────────────
    #  Registration Status Tracking
    # ──────────────────────────────────────────────

    def _set_status(self, reg_number: str, status: str, error: str | None = None):
        """Thread-safe registration status update."""
        with self._status_lock:
            self._registration_status[reg_number] = {
                "status": status,
                "error": error,
            }

    def get_registration_status(self, reg_number: str) -> dict:
        """Get the current embedding processing status for a student."""
        with self._status_lock:
            return self._registration_status.get(
                reg_number, {"status": "unknown", "error": None}
            )

    def get_all_registration_statuses(self) -> dict:
        """Get processing statuses for all students (for bulk frontend polling)."""
        with self._status_lock:
            return dict(self._registration_status)

    # ──────────────────────────────────────────────
    #  Registration (Background Queue)
    # ──────────────────────────────────────────────

    def register_face(
        self,
        reg_number: str,
        image_bytes: bytes,
        cleanup_image_on_failure: bool = True,
        save_image: bool = True,
    ) -> bool:
        """
        Registers a student's face:
        1. Saves the original image synchronously (for display in the app).
        2. Queues embedding extraction in a background thread (non-blocking).
        Returns immediately so the user can register the next student.

        `save_image=False` is for the *second* backend when one photo is being
        registered into both: the photograph is shared, so writing it twice is
        pointless, and the two backends racing to write the same path is worse
        than pointless.
        """
        img_path = os.path.join(self.known_faces_dir, f"{reg_number}.jpg")
        nparr = np.frombuffer(image_bytes, np.uint8)
        img = cv2.imdecode(nparr, cv2.IMREAD_COLOR)

        if img is None:
            raise ValueError("Could not decode image. Please try a different photo.")

        # Save a high-quality copy for display in the app
        if save_image and not cv2.imwrite(img_path, img, [cv2.IMWRITE_JPEG_QUALITY, 95]):
            raise ValueError("Could not save face image. Check write permissions.")

        # Mark as processing and queue the heavy embedding work
        self._set_status(reg_number, "processing")
        self._executor.submit(
            self._process_embedding,
            reg_number,
            img.copy(),
            cleanup_image_on_failure,
        )

        print(f"[OK] Saved image & queued embedding extraction for {reg_number}")
        return True

    def _process_embedding(
        self,
        reg_number: str,
        img: np.ndarray,
        cleanup_image_on_failure: bool = True,
    ):
        """
        Background worker: preprocessing + detection + embedding extraction.
        Runs in the thread pool so it doesn't block the API.
        """
        try:
            # Apply CLAHE preprocessing for consistent lighting
            preprocessed = self._preprocess_image(img)

            # Extract embedding(s) using the backend-specific method
            results = self._extract_embeddings(preprocessed, enforce_detection=True)

            if not results:
                self._set_status(reg_number, "failed", "No face detected in the image.")
                if cleanup_image_on_failure:
                    self._cleanup_image(reg_number)
                return

            # Enrollment must have exactly one face. Silently keeping the
            # first RetinaFace result can bind a bystander to this student.
            if len(results) != 1:
                self._set_status(
                    reg_number,
                    "failed",
                    f"Expected exactly one face in the registration image; found {len(results)}.",
                )
                if cleanup_image_on_failure:
                    self._cleanup_image(reg_number)
                return

            embedding, _crop, _meta = results[0]
            vec = self._normalize(embedding)

            # Remove old entry if re-registering the same student
            # Firestore first. If the durable write fails the registration has
            # not happened, and adding it to the in-memory index anyway would
            # make a student who vanishes on the next restart look enrolled.
            self.db.save_embedding(self.backend_name, reg_number, vec.reshape(-1).tolist())

            with self._index_lock:
                self._remove_from_memory_index(reg_number)
                faiss_id = self._next_id
                self._next_id += 1
                self._index.add_with_ids(vec, np.array([faiss_id], dtype=np.int64))
                self._id_map[faiss_id] = reg_number

            self._set_status(reg_number, "completed")
            print(f"[OK] Registered {reg_number} ({self.backend_name}, id={faiss_id}, dim={vec.shape[1]})")

        except Exception as e:
            self._set_status(reg_number, "failed", str(e))
            if cleanup_image_on_failure:
                self._cleanup_image(reg_number)
            print(f"[ERROR] Failed to process embedding for {reg_number}: {e}")

    def _cleanup_image(self, reg_number: str):
        """Remove the saved image on embedding failure."""
        img_path = os.path.join(self.known_faces_dir, f"{reg_number}.jpg")
        if os.path.exists(img_path):
            os.remove(img_path)

    # ──────────────────────────────────────────────
    #  Deletion
    # ──────────────────────────────────────────────

    def _remove_from_memory_index(self, reg_number: str):
        """Drop a student from the searchable copy. Caller holds `_index_lock`."""
        ids_to_remove = [fid for fid, rn in self._id_map.items() if rn == reg_number]
        if ids_to_remove:
            self._index.remove_ids(np.array(ids_to_remove, dtype=np.int64))
            for fid in ids_to_remove:
                del self._id_map[fid]

    def forget(self, reg_number: str):
        """
        Drop a student from this backend's in-memory index only.

        Used when another backend has already done the durable deletion — the
        photograph and every stored vector are gone, and this service just
        needs to stop returning somebody who no longer exists.
        """
        with self._index_lock:
            self._remove_from_memory_index(reg_number)
        with self._status_lock:
            self._registration_status.pop(reg_number, None)

    def delete_face(self, reg_number: str) -> bool:
        """
        Remove a student's photo and their stored vectors.

        Vectors are deleted for **every** backend, not just the active one.
        Deleting someone should not leave them recognisable after a backend
        switch — that is how a "deleted" student comes back from the dead.
        """
        img_path = os.path.join(self.known_faces_dir, f"{reg_number}.jpg")
        if os.path.exists(img_path):
            os.remove(img_path)
            print(f"[OK] Deleted face image for {reg_number}")
        else:
            print(f"[WARN] No face image found for {reg_number}")

        self.db.delete_all_embeddings_for_student(reg_number)
        with self._index_lock:
            self._remove_from_memory_index(reg_number)

        # Clean up registration status
        with self._status_lock:
            self._registration_status.pop(reg_number, None)

        print(f"[OK] Removed {reg_number} from every stored index.")
        return True

    # ──────────────────────────────────────────────
    #  Attendance (Group Photo Matching)
    # ──────────────────────────────────────────────

    # Number of nearest neighbours kept per face as identification candidates.
    # The classification margin still uses only the top two, so raising this
    # gives the Adjudicator more options to show a vision model without
    # changing how present/unsure is decided.
    CANDIDATE_K = 4

    def warm_up(self):
        """
        Run one throwaway detection so the first real scan doesn't pay for it.

        RetinaFace builds its TensorFlow graph and probes CPU features on the
        very first call in a process. Measured here: 67s for the first
        detection versus a few seconds afterwards. Left unwarmed, that entire
        cost lands on whoever takes the first photo — which at a demo is the
        one scan anybody watches.

        Safe to call in a background thread; failures are logged and ignored,
        because a warm-up is an optimisation and must never stop the server.
        """
        try:
            sample_path = None
            if os.path.isdir(self.known_faces_dir):
                for name in sorted(os.listdir(self.known_faces_dir)):
                    if name.lower().endswith(".jpg"):
                        sample_path = os.path.join(self.known_faces_dir, name)
                        break

            img = cv2.imread(sample_path) if sample_path else None
            if img is None:
                # No registration photos yet — a synthetic image still builds
                # the graph, it just won't find a face.
                img = np.full((256, 256, 3), 127, dtype=np.uint8)

            self._extract_embeddings(self._preprocess_image(img), enforce_detection=False)

            # The detector builds a separate graph per input shape, so warm the
            # Adjudicator's fixed re-crop canvas too. Without this, the first
            # face that needs re-cropping pays that build mid-scan — and it is
            # charged to the investigation's time budget.
            from services.adjudicator import RESCAN_CANVAS_PX

            canvas = np.full((RESCAN_CANVAS_PX, RESCAN_CANVAS_PX, 3), 127, dtype=np.uint8)
            self._extract_embeddings(canvas, enforce_detection=False)

            print(f"[OK] {self.backend_name.upper()} detector warmed up; first scan will not pay graph-build cost.")
        except Exception as e:
            print(f"[WARN] Detector warm-up failed (first scan will be slower): {e}")

    def _decode_group_photo(self, image_bytes: bytes) -> np.ndarray:
        """Decode an uploaded group photo, raising a user-facing error if invalid."""
        if self._index.ntotal == 0:
            raise ValueError("No face embeddings in the database. Register students first.")

        nparr = np.frombuffer(image_bytes, np.uint8)
        img = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
        if img is None:
            raise ValueError("Could not decode the group photo. Please try another image.")
        return img

    def search_embedding(self, embedding: np.ndarray, reg_to_name: dict) -> dict:
        """
        Runs one embedding against FAISS and returns the raw comparison facts.

        Split out so the Adjudicator can re-search a re-processed face without
        duplicating the scoring or candidate-filtering rules.
        """
        query_vec = self._normalize(embedding)
        # A registration can land mid-scan, and FAISS does not tolerate a write
        # arriving while a search is in flight. The lock is held only for the
        # search itself, which is microseconds against 12 vectors.
        with self._index_lock:
            k = min(self.CANDIDATE_K + 1, self._index.ntotal)
            scores, ids = self._index.search(query_vec, k=k)
            id_map = dict(self._id_map)

        best_score = float(scores[0][0])  # Cosine similarity (0 to 1)
        best_id = int(ids[0][0])
        # The margin deliberately stays a top-1-vs-top-2 comparison. A close
        # runner-up is an ambiguous identity even when the best score alone
        # clears the threshold, and widening the search must not change that.
        runner_up_score = float(scores[0][1]) if k >= 2 else None
        score_margin = (
            best_score - runner_up_score if runner_up_score is not None else float("inf")
        )

        # Candidate shortlist: every neighbour that is still an enrolled
        # student. An index can temporarily contain an identity deleted from
        # Firestore, which must never be offered as an answer.
        candidates = []
        seen = set()
        for rank in range(k):
            cand_id = int(ids[0][rank])
            if cand_id == -1:
                continue
            cand_reg = id_map.get(cand_id)
            if cand_reg is None or cand_reg in seen or cand_reg not in reg_to_name:
                continue
            seen.add(cand_reg)
            candidates.append(
                {
                    "reg_number": cand_reg,
                    "name": reg_to_name[cand_reg],
                    "score": float(scores[0][rank]),
                }
            )

        top_reg = id_map.get(best_id) if best_id != -1 else None
        skip_reason = None
        if best_id == -1:
            skip_reason = "no_neighbour"
        elif top_reg is None:
            skip_reason = "unmapped_index_id"
        elif top_reg not in reg_to_name:
            skip_reason = "stale_identity"

        return {
            "best_score": best_score,
            "margin": score_margin,
            "top_reg": top_reg,
            "skip_reason": skip_reason,
            "candidates": candidates,
        }

    def classify_score(self, best_score: float, margin: float) -> str:
        """
        The three-tier rule, in one place: confident / uncertain / unrecognized.

        `unrecognized` is what the old code silently dropped. It is kept as a
        real tier because those faces are exactly the ones worth investigating:
        a genuinely bad crop of an enrolled student and a stranger who walked
        into the room both land here, and only a closer look tells them apart.
        """
        if best_score >= self.match_threshold and margin >= self.match_margin:
            return "confident"
        if best_score >= self.unsure_threshold:
            return "uncertain"
        return "unrecognized"

    def analyze_faces(self, preprocessed: np.ndarray, reg_to_name: dict) -> list[dict]:
        """
        First pass over a group photo: detect every face, score it against the
        index, and return one self-contained record per face.

        Records are keyed by `face_id` (position in the photo), never by
        reg_number. Two different people in a group photo can both come back
        with the same top-1 guess, and identity-keyed state silently merges
        them into one.
        """
        results = self._extract_embeddings(preprocessed, enforce_detection=False)
        print(f"[INFO] Found {len(results)} face(s) in group photo.")

        records = []
        for face_id, (embedding, crop, meta) in enumerate(results):
            search = self.search_embedding(embedding, reg_to_name)
            record = {
                "face_id": face_id,
                "embedding": embedding,
                "crop": crop,
                "facial_area": meta.get("facial_area", {}),
                "detector_confidence": meta.get("detector_confidence", 0.0),
                "tier": self.classify_score(search["best_score"], search["margin"]),
                **search,
            }
            records.append(record)
        return records

    def _assemble_result(
        self,
        all_students: list,
        recognized_reg_numbers: set,
        unsure_reg_numbers: set,
        vlm_verified_reg_numbers: set,
        processing: dict,
        evidence: dict | None = None,
    ) -> dict:
        """Build the API response shape from the final per-identity verdicts."""
        evidence = evidence or {}
        present, absent, unsure = [], [], []
        for student in all_students:
            reg = student["reg_number"]
            entry = {
                "name": student["name"],
                "reg_number": reg,
                "vlm_verified": reg in vlm_verified_reg_numbers,
            }
            entry.update(evidence.get(reg, {}))
            if reg in recognized_reg_numbers:
                present.append(entry)
            elif reg in unsure_reg_numbers:
                unsure.append(entry)
            else:
                absent.append(entry)

        return {
            "present": present,
            "absent": absent,
            "unsure": unsure,
            "recognized_count": len(recognized_reg_numbers),
            "recognized_reg_numbers": list(recognized_reg_numbers),
            "unsure_count": len(unsure_reg_numbers),
            "processing": processing,
        }

    def take_attendance(self, image_bytes: bytes, all_students: list) -> dict:
        """
        Takes a group photo, detects all faces, extracts embeddings,
        and matches them against the FAISS index using Cosine Similarity.
        """
        img = self._decode_group_photo(image_bytes)

        # Apply CLAHE preprocessing for consistent lighting
        preprocessed = self._preprocess_image(img)

        recognized_reg_numbers = set()
        unsure_reg_numbers = set()
        processing = {"status": "success", "error": None}
        vlm_verified_reg_numbers = set()

        try:
            # Create a mapping for friendly logging
            reg_to_name = {s.get("reg_number"): s.get("name", "Unknown") for s in all_students}

            vlm_tasks = []

            for record in self.analyze_faces(preprocessed, reg_to_name):
                if record["skip_reason"] == "stale_identity":
                    print(f"[WARN] Skipping stale index identity: {record['top_reg']}")
                    continue
                if record["skip_reason"]:
                    continue

                reg_number = record["top_reg"]
                name = reg_to_name[reg_number]
                best_score = record["best_score"]
                score_margin = record["margin"]

                if record["tier"] == "confident":
                    recognized_reg_numbers.add(reg_number)
                    unsure_reg_numbers.discard(reg_number)
                    print(
                        f"[OK] Match: {name} [{reg_number}] "
                        f"(cosine={best_score:.4f}, margin={score_margin:.4f})"
                    )
                elif record["tier"] == "uncertain":
                    if reg_number not in recognized_reg_numbers:
                        unsure_reg_numbers.add(reg_number)
                        vlm_tasks.append({"reg_number": reg_number, "crop": record["crop"]})
                    print(
                        f"[UNSURE] Weak or ambiguous match: {name} [{reg_number}] "
                        f"(cosine={best_score:.4f}, margin={score_margin:.4f})"
                    )
                else:
                    print(
                        f"[SKIP] Below threshold: {name} [{reg_number}] "
                        f"(cosine={best_score:.4f}, margin={score_margin:.4f})"
                    )

            # Process VLM Verification for unsure faces
            if vlm_tasks and self.vlm_service.is_configured:
                import concurrent.futures
                print(f"[INFO] Running VLM verification on {len(vlm_tasks)} unsure faces...")

                def verify_single(task):
                    r_num = task["reg_number"]
                    f_crop = task["crop"]
                    known_path = os.path.join(self.known_faces_dir, f"{r_num}.jpg")
                    try:
                        with open(known_path, "rb") as f:
                            known_bytes = f.read()
                        _, buffer = cv2.imencode('.jpg', f_crop)
                        crop_bytes = buffer.tobytes()
                        verdict = self.vlm_service.verify_match(known_bytes, crop_bytes)
                        return r_num, verdict
                    except Exception as e:
                        print(f"[WARN] VLM task failed for {r_num}: {e}")
                        return r_num, "error"

                vlm_workers = int(os.getenv("VLM_MAX_WORKERS", "5"))
                with concurrent.futures.ThreadPoolExecutor(max_workers=vlm_workers) as executor:
                    futures = [executor.submit(verify_single, t) for t in vlm_tasks]
                    for future in concurrent.futures.as_completed(futures):
                        r_num, verdict = future.result()
                        if verdict == "yes":
                            print(f"[OK] VLM upgraded {r_num} to Present.")
                            recognized_reg_numbers.add(r_num)
                            unsure_reg_numbers.discard(r_num)
                            vlm_verified_reg_numbers.add(r_num)
                        elif verdict == "no":
                            print(f"[REJECTED] VLM denied {r_num}.")
                        else:
                            # "error": VLM call failed (timeout/network/bad key).
                            # This is NOT the same as Gemini saying "no" — leave
                            # the face unsure instead of silently rejecting it.
                            print(f"[WARN] VLM verification errored for {r_num}; leaving as unsure.")

        except ValueError:
            raise
        except Exception as exc:
            processing["status"] = "partial"
            processing["error"] = str(exc)
            print(f"[ERROR] Face processing error: {exc}")

        print(f"Total recognized: {len(recognized_reg_numbers)} | Unsure: {len(unsure_reg_numbers)}")

        return self._assemble_result(
            all_students=all_students,
            recognized_reg_numbers=recognized_reg_numbers,
            unsure_reg_numbers=unsure_reg_numbers,
            vlm_verified_reg_numbers=vlm_verified_reg_numbers,
            processing=processing,
        )

    # ──────────────────────────────────────────────
    #  Attendance (Agentic / Adjudicated)
    # ──────────────────────────────────────────────

    def take_attendance_agentic(
        self,
        image_bytes: bytes,
        all_students: list,
        emit=None,
    ) -> dict:
        """
        Same job as take_attendance(), but every face the local model is not
        sure about is handed to the Adjudicator, which investigates it with
        whichever tool fits and reports its reasoning through `emit`.

        `emit(event: dict)` is called as the work happens so a client can watch
        the investigation live instead of waiting for a verdict.
        """
        from services.adjudicator import AttendanceAdjudicator

        img = self._decode_group_photo(image_bytes)
        preprocessed = self._preprocess_image(img)
        reg_to_name = {s.get("reg_number"): s.get("name", "Unknown") for s in all_students}

        adjudicator = AttendanceAdjudicator(face_service=self, emit=emit)
        return adjudicator.run(
            original_img=img,
            preprocessed_img=preprocessed,
            all_students=all_students,
            reg_to_name=reg_to_name,
        )
