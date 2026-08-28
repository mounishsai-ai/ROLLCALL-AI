"""
AdaFace face recognition backend.

Uses:
- DeepFace's built-in RetinaFace for face detection + landmarks
- AdaFace IR-50 (PyTorch) for embedding extraction
- 5-point landmark alignment to 112x112 canonical face crops
- CLAHE preprocessing (inherited from BaseFaceService)
- FAISS for vector storage (inherited from BaseFaceService)

Note: We use DeepFace ONLY for face detection/alignment (RetinaFace),
NOT for embedding extraction. The embedding comes from AdaFace.
"""

import os

import cv2
import numpy as np
import torch
from deepface import DeepFace
from deepface.commons import image_utils

from services.adaface_net import load_pretrained_model
from services.base_face_service import BaseFaceService

# Standard 112x112 reference landmarks for face alignment. The order is the
# image-coordinate order used by ArcFace / AdaFace: viewer-left eye, viewer-
# right eye, nose, viewer-left mouth corner, viewer-right mouth corner.
REFERENCE_LANDMARKS = np.array(
    [
        [38.2946, 51.6963],  # left eye
        [73.5318, 51.5014],  # right eye
        [56.0252, 71.7366],  # nose tip
        [41.5493, 92.3655],  # left mouth corner
        [70.7299, 92.2041],  # right mouth corner
    ],
    dtype=np.float32,
)


class AdaFaceService(BaseFaceService):
    """
    Face recognition using AdaFace IR-50 + RetinaFace detection.

    AdaFace is specifically designed for quality-adaptive face recognition,
    making it ideal for group photos where face quality varies significantly.
    """

    def __init__(
        self,
        known_faces_dir: str = "known_faces",
        match_threshold: float = 0.40,
        unsure_threshold: float = 0.35,
        match_margin: float = 0.05,
    ):
        # Load AdaFace model
        model_path = os.getenv(
            "ADAFACE_MODEL_PATH", "pretrained/adaface_ir50_ms1mv2.ckpt"
        )
        architecture = os.getenv("ADAFACE_ARCHITECTURE", "ir_50")

        if not os.path.exists(model_path):
            raise FileNotFoundError(
                f"AdaFace model not found at: {model_path}\n"
                f"Run 'python download_model.py' to download it, or set "
                f"ADAFACE_MODEL_PATH in .env to the correct path."
            )

        # Select device: GPU if available, otherwise CPU
        self._device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        print(f"[INFO] Loading AdaFace {architecture} on {self._device}...")

        self._model = load_pretrained_model(
            architecture=architecture, checkpoint_path=model_path
        )
        self._model = self._model.to(self._device)
        self._model.eval()

        print(f"[OK] AdaFace model loaded ({architecture} on {self._device})")

        # Initialize base class (FAISS, queue, status)
        match_threshold = float(os.getenv("DEEPFACE_MATCH_THRESHOLD", str(match_threshold)))
        unsure_threshold = float(os.getenv("DEEPFACE_UNSURE_THRESHOLD", str(unsure_threshold)))

        super().__init__(
            known_faces_dir=known_faces_dir,
            backend_name="adaface",
            match_threshold=match_threshold,
            unsure_threshold=unsure_threshold,
        )

    # ──────────────────────────────────────────────
    #  Face Alignment
    # ──────────────────────────────────────────────

    @staticmethod
    def _align_face_landmarks(img: np.ndarray, facial_area: dict) -> np.ndarray:
        """Align a face to 112x112 using RetinaFace landmarks.

        RetinaFace names eyes from the subject's perspective: its ``left_eye``
        appears on the viewer's right. The ArcFace template is ordered in image
        coordinates, so source landmarks must be reordered before fitting the
        transform. Reversing this correspondence rotates faces close to 180
        degrees and damages the embedding quality.
        """
        # Five points are more stable for tilted or mildly posed faces. The
        # fallback still uses the correct viewer-left / viewer-right order.
        landmark_keys = ("right_eye", "left_eye", "nose", "mouth_right", "mouth_left")
        if all(facial_area.get(key) is not None for key in landmark_keys):
            src_pts = np.array([facial_area[key] for key in landmark_keys], dtype=np.float32)
            dst_pts = REFERENCE_LANDMARKS
        else:
            right_eye = facial_area.get("right_eye")
            left_eye = facial_area.get("left_eye")
            if right_eye is None or left_eye is None:
                return AdaFaceService._crop_face(img, facial_area)
            src_pts = np.array([right_eye, left_eye], dtype=np.float32)
            dst_pts = REFERENCE_LANDMARKS[:2]

        # Estimate a similarity transform (rotation, scale, translation).
        transform_matrix, _ = cv2.estimateAffinePartial2D(
            src_pts.reshape(-1, 1, 2), dst_pts.reshape(-1, 1, 2), method=cv2.LMEDS
        )

        if transform_matrix is None:
            return AdaFaceService._crop_face(img, facial_area)

        # Warp the face to the canonical alignment
        aligned = cv2.warpAffine(
            img,
            transform_matrix,
            (112, 112),
            borderValue=(0, 0, 0),
        )
        return aligned

    @staticmethod
    def _crop_face(img: np.ndarray, facial_area: dict) -> np.ndarray:
        """Crop a face from the image using facial_area coordinates and resize to 112x112."""
        x = facial_area.get("x", 0)
        y = facial_area.get("y", 0)
        w = facial_area.get("w", 0)
        h = facial_area.get("h", 0)

        # Add some padding (20%) for better face coverage
        pad_w = int(w * 0.2)
        pad_h = int(h * 0.2)
        y1 = max(0, y - pad_h)
        y2 = min(img.shape[0], y + h + pad_h)
        x1 = max(0, x - pad_w)
        x2 = min(img.shape[1], x + w + pad_w)

        cropped = img[y1:y2, x1:x2]
        if cropped.size == 0:
            cropped = img  # fallback to full image
        return cv2.resize(cropped, (112, 112))

    # ──────────────────────────────────────────────
    #  Preprocessing for AdaFace Model
    # ──────────────────────────────────────────────

    def _preprocess_for_model(self, face_bgr: np.ndarray) -> torch.Tensor:
        """
        Convert a 112x112 BGR face crop to an AdaFace input tensor.

        AdaFace preprocessing:
        1. Input is BGR (OpenCV format) — no conversion needed
        2. Normalize: (pixel / 255 - 0.5) / 0.5 → range [-1, 1]
        3. Transpose: HWC → CHW
        4. Add batch dimension
        """
        img = face_bgr.astype(np.float32)
        img = ((img / 255.0) - 0.5) / 0.5  # normalize to [-1, 1]
        img = img.transpose(2, 0, 1)  # HWC → CHW
        tensor = torch.from_numpy(img).unsqueeze(0)  # add batch dim
        return tensor.to(self._device)

    # ──────────────────────────────────────────────
    #  Embedding Extraction (implements abstract method)
    # ──────────────────────────────────────────────

    def _extract_embeddings(
        self, img: np.ndarray, enforce_detection: bool = True
    ) -> list[tuple[np.ndarray, np.ndarray, dict]]:
        """
        Detect faces with DeepFace's RetinaFace, align to 112x112, and extract
        AdaFace embeddings.

        Uses DeepFace.extract_faces() for RetinaFace detection only. Face
        alignment is performed below so the crop exactly matches AdaFace's
        landmark template. The embedding comes from the AdaFace PyTorch model.

        Args:
            img: BGR image (CLAHE already applied).
            enforce_detection: Raise ValueError if no faces found.

        Returns:
            List of tuples (embedding_vector, face_crop_image, meta). `meta`
            carries the detection box in the coordinates of `img`. It matters
            more here than for ArcFace: the crop returned alongside the
            embedding is the 112x112 aligned face the model consumes, which is
            too small and too tightly cropped to show a vision model or a
            human. The box lets callers cut a natural-looking face from the
            full-resolution photo instead.
        """
        # Use DeepFace's RetinaFace detector to find all faces
        try:
            face_objs = DeepFace.extract_faces(
                img_path=img,
                detector_backend="retinaface",
                enforce_detection=enforce_detection,
                align=False,
                color_face="bgr",
                normalize_face=False,
            )
        except ValueError:
            if enforce_detection:
                raise
            return []

        if not face_objs:
            if enforce_detection:
                raise ValueError("No face detected in the image.")
            return []

        results = []

        for face_obj in face_objs:
            try:
                confidence = face_obj.get("confidence", 0)
                if confidence < 0.5:
                    continue

                facial_area = face_obj.get("facial_area", {})
                aligned_face = self._align_face_landmarks(img, facial_area)

                # Preprocess for AdaFace model
                input_tensor = self._preprocess_for_model(aligned_face)

                # Extract embedding
                with torch.no_grad():
                    embedding = self._model(input_tensor)

                # Convert to numpy and flatten
                embedding_np = embedding.cpu().numpy().flatten()
                meta = {
                    "facial_area": {
                        "x": int(facial_area.get("x", 0)),
                        "y": int(facial_area.get("y", 0)),
                        "w": int(facial_area.get("w", 0)),
                        "h": int(facial_area.get("h", 0)),
                    },
                    "detector_confidence": float(confidence),
                }
                results.append((embedding_np, aligned_face, meta))

            except Exception as e:
                print(f"[WARN] Failed to process face: {e}")
                continue

        if not results and enforce_detection:
            raise ValueError("No face detected in the image.")

        return results
