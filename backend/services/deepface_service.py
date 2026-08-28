"""
ArcFace face recognition backend (via DeepFace library).

Uses:
- RetinaFace (via DeepFace) for face detection + alignment
- ArcFace (via DeepFace) for embedding extraction
- CLAHE preprocessing (inherited from BaseFaceService)
- FAISS for vector storage (inherited from BaseFaceService)
"""

import os

import numpy as np
from deepface import DeepFace

from services.base_face_service import BaseFaceService


class DeepFaceService(BaseFaceService):
    """
    Face recognition using ArcFace via the DeepFace library.
    Uses RetinaFace detector for both registration and attendance.
    """

    def __init__(
        self,
        known_faces_dir: str = "known_faces",
        match_threshold: float = 0.40,
        unsure_threshold: float = 0.35,
        match_margin: float = 0.05,
    ):
        match_threshold = float(os.getenv("DEEPFACE_MATCH_THRESHOLD", str(match_threshold)))
        unsure_threshold = float(os.getenv("DEEPFACE_UNSURE_THRESHOLD", str(unsure_threshold)))

        super().__init__(
            known_faces_dir=known_faces_dir,
            backend_name="arcface",
            match_threshold=match_threshold,
            unsure_threshold=unsure_threshold,
        )

    # ──────────────────────────────────────────────
    #  Embedding Extraction (implements abstract method)
    # ──────────────────────────────────────────────

    def _extract_embeddings(
        self, img: np.ndarray, enforce_detection: bool = True
    ) -> list[tuple[np.ndarray, np.ndarray, dict]]:
        """
        Detect faces and extract ArcFace embeddings using DeepFace.

        DeepFace.represent() handles detection (RetinaFace) + alignment +
        embedding (ArcFace) in a single call.

        Args:
            img: BGR image (CLAHE already applied).
            enforce_detection: Raise ValueError if no faces found.

        Returns:
            List of tuples (embedding_vector, face_crop_image, meta). `meta`
            carries the detection box in the coordinates of `img`, which the
            Adjudicator uses to re-crop a face from the original photo at a
            different scale when a first-pass match is unconvincing.
        """
        # DeepFace.represent() accepts numpy arrays directly
        # — avoids JPEG compression artifacts from saving to disk
        representations = DeepFace.represent(
            img_path=img,
            model_name="ArcFace",
            detector_backend="retinaface",
            enforce_detection=enforce_detection,
            align=True,
        )

        if not representations:
            if enforce_detection:
                raise ValueError("No face detected in the image.")
            return []

        results = []
        for rep in representations:
            embedding = np.array(rep["embedding"])
            facial_area = rep.get("facial_area", {})
            x = facial_area.get("x", 0)
            y = facial_area.get("y", 0)
            w = facial_area.get("w", 0)
            h = facial_area.get("h", 0)
            
            # Simple crop for the returned image (DeepFace already aligned internally for the embedding)
            # Add some padding (20%) for better face coverage in VLM
            pad_w = int(w * 0.2)
            pad_h = int(h * 0.2)
            y1 = max(0, y - pad_h)
            y2 = min(img.shape[0], y + h + pad_h)
            x1 = max(0, x - pad_w)
            x2 = min(img.shape[1], x + w + pad_w)
            
            cropped_face = img[y1:y2, x1:x2]
            if cropped_face.size == 0:
                cropped_face = img

            meta = {
                "facial_area": {"x": int(x), "y": int(y), "w": int(w), "h": int(h)},
                "detector_confidence": float(rep.get("face_confidence", 0.0) or 0.0),
            }
            results.append((embedding, cropped_face, meta))

        return results
