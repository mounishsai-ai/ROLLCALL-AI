"""
Firestore: the one place data outlives a process.

Two kinds of thing live here.

**Roster and attendance** — names, registration numbers, who was present on a
given day. Obvious database material.

**Face embeddings** — the 512 numbers each recognition model produces for a
face. These used to be written to a `faiss.index` file on local disk, which was
correct on a laptop and wrong the moment the backend runs on Cloud Run: the
container's disk is thrown away on every restart, and a Cloud Storage mount is
not a safe place for a file that is opened, seeked and rewritten in place.

So Firestore holds the vectors and FAISS is rebuilt in memory from them at
startup. FAISS stops being storage and goes back to being what it is good at —
a fast search structure over vectors somebody else is keeping safe. Twelve
students is 12 small documents; this costs nothing and removes a whole class of
"the index disappeared" problem.

**Embeddings are stored per recognition backend, and this is not optional.**

ArcFace and AdaFace describe the same face in two languages that share no
vocabulary. Measured on this project's own data: two vectors of the *same
student* from the *same model* score 1.0000 against each other, while the same
student across the two models scores 0.016 on average — indistinguishable from
two strangers. Cosine similarity is only meaningful inside one model's space.

So every document carries a `backend` field, every read filters on it, and a
vector is only ever compared with others made by the same model. Registering
one photograph into both backends means **running both models over it** and
storing two independent vectors — never copying one across, which would turn
every subsequent match into noise.

If you are ever tempted to merge these into one collection, or to reuse a
vector when the other backend is missing one: don't. Regenerate it from the
photograph instead (`sync_faces.py --all-backends`).
"""

from datetime import datetime, timezone

import firebase_admin
from firebase_admin import credentials, firestore

# One document per (backend, student). The id is deterministic so a
# re-registration overwrites rather than accumulating duplicates.
EMBEDDINGS_COLLECTION = "face_embeddings"


class FirebaseDBService:
    def __init__(self, credentials_path: str):
        self.credentials_path = credentials_path

        cred = credentials.Certificate(self.credentials_path)

        # Prevent initializing twice if the server restarts
        if not firebase_admin._apps:
            firebase_admin.initialize_app(cred)

        self.db = firestore.client()

    # ──────────────────────────────────────────────
    #  Roster
    # ──────────────────────────────────────────────

    def add_student(self, name: str, reg_number: str, face_id: str):
        doc_ref = self.db.collection("students").document(reg_number)
        doc_ref.set(
            {
                "name": name,
                "reg_number": reg_number,
                "face_id": face_id,
            }
        )
        return True

    def get_all_students(self):
        students = self.db.collection("students").stream()
        return [doc.to_dict() for doc in students]

    def delete_student(self, reg_number: str):
        self.db.collection("students").document(reg_number).delete()
        return True

    # ──────────────────────────────────────────────
    #  Attendance
    # ──────────────────────────────────────────────

    def log_attendance(self, present_reg_numbers: list):
        """
        Record who was present today.

        This **replaces** the day's list rather than adding to it. The previous
        version used ArrayUnion, which can only ever add a name: a student
        wrongly marked present could never be un-marked, by this system or by
        the teacher, because nothing could remove them. Re-scanning the room is
        now a correction rather than an accumulation.

        The consequence, stated plainly: one document per calendar day means a
        second scan overwrites the first. That is right for one class a day and
        wrong for two, and it is the next thing to change if this is ever used
        for more than one session — `attendance_logs/<date>/sessions/<id>` is
        the shape it wants.
        """
        today = datetime.now().strftime("%Y-%m-%d")
        log_ref = self.db.collection("attendance_logs").document(today)

        log_ref.set(
            {
                "date": today,
                "timestamp": firestore.SERVER_TIMESTAMP,
                "present_students": list(present_reg_numbers),
                # A scan's own opinion, not a human's. `confirm_attendance`
                # flips this, and the difference matters: a register nobody
                # signed off is a draft, however confident the machine was.
                "confirmed_by_teacher": False,
            }
        )
        return True

    def confirm_attendance(self, present_reg_numbers: list, date: str | None = None) -> dict:
        """
        Record the register a teacher actually signed off.

        This is the one that counts. A scan produces a proposal; a person
        decides. Until now there was no way to record that decision at all —
        whatever the scan concluded simply became the record, which is fine for
        a demo and not fine for something a student's attendance depends on.

        Replaces the day's list outright, so correcting a mistake is just
        confirming again.
        """
        day = date or datetime.now().strftime("%Y-%m-%d")
        log_ref = self.db.collection("attendance_logs").document(day)

        payload = {
            "date": day,
            "timestamp": firestore.SERVER_TIMESTAMP,
            "present_students": list(present_reg_numbers),
            "confirmed_by_teacher": True,
            "confirmed_at": datetime.now(timezone.utc).isoformat(),
        }
        log_ref.set(payload)
        return {"date": day, "present_count": len(present_reg_numbers)}

    def get_attendance(self, date: str | None = None) -> dict:
        """Read back one day's register, so a teacher can see what was signed off."""
        day = date or datetime.now().strftime("%Y-%m-%d")
        doc = self.db.collection("attendance_logs").document(day).get()
        if not doc.exists:
            return {"date": day, "present_students": [], "confirmed_by_teacher": False}
        data = doc.to_dict() or {}
        return {
            "date": day,
            "present_students": data.get("present_students", []),
            "confirmed_by_teacher": data.get("confirmed_by_teacher", False),
            "confirmed_at": data.get("confirmed_at"),
        }

    # ──────────────────────────────────────────────
    #  Face embeddings (per recognition backend)
    # ──────────────────────────────────────────────

    @staticmethod
    def _embedding_doc_id(backend: str, reg_number: str) -> str:
        return f"{backend}__{reg_number}"

    def save_embedding(self, backend: str, reg_number: str, vector: list) -> bool:
        """Store one student's face vector for one recognition backend."""
        doc_id = self._embedding_doc_id(backend, reg_number)
        self.db.collection(EMBEDDINGS_COLLECTION).document(doc_id).set(
            {
                "reg_number": reg_number,
                "backend": backend,
                "dim": len(vector),
                "vector": [float(v) for v in vector],
                "updated_at": datetime.now(timezone.utc).isoformat(),
            }
        )
        return True

    def get_embeddings(self, backend: str) -> list[dict]:
        """Every stored vector for one backend, as {reg_number, vector}."""
        query = self.db.collection(EMBEDDINGS_COLLECTION).where(
            filter=firestore.FieldFilter("backend", "==", backend)
        )
        out = []
        for doc in query.stream():
            data = doc.to_dict() or {}
            vector = data.get("vector")
            reg_number = data.get("reg_number")
            if not reg_number or not vector:
                continue
            out.append({"reg_number": reg_number, "vector": vector})
        return out

    def get_indexed_reg_numbers(self, backend: str) -> list[str]:
        """
        Which students have a usable face vector for this backend.

        This is what the app's per-student badges are built from, and it now
        comes from the database rather than from reading FAISS's private files
        off disk.
        """
        return sorted({e["reg_number"] for e in self.get_embeddings(backend)})

    def delete_embedding(self, backend: str, reg_number: str) -> bool:
        doc_id = self._embedding_doc_id(backend, reg_number)
        self.db.collection(EMBEDDINGS_COLLECTION).document(doc_id).delete()
        return True

    def delete_all_embeddings_for_student(self, reg_number: str) -> bool:
        """Remove a student from every backend's vectors, not just the active one."""
        query = self.db.collection(EMBEDDINGS_COLLECTION).where(
            filter=firestore.FieldFilter("reg_number", "==", reg_number)
        )
        for doc in query.stream():
            doc.reference.delete()
        return True

    def delete_backend_embeddings(self, backend: str) -> int:
        """Wipe one backend's vectors. Used by a full index rebuild."""
        query = self.db.collection(EMBEDDINGS_COLLECTION).where(
            filter=firestore.FieldFilter("backend", "==", backend)
        )
        count = 0
        for doc in query.stream():
            doc.reference.delete()
            count += 1
        return count
