import io
from azure.ai.vision.face import FaceAdministrationClient, FaceClient
from azure.ai.vision.face.models import FaceDetectionModel, FaceRecognitionModel
from azure.core.credentials import AzureKeyCredential


class AzureFaceService:
    def __init__(self, endpoint: str, key: str):
        self.group_id = "classroom-group"
        credential = AzureKeyCredential(key)

        # Two clients: one for managing people, one for detecting/identifying faces
        self.admin_client = FaceAdministrationClient(endpoint=endpoint, credential=credential)
        self.face_client = FaceClient(endpoint=endpoint, credential=credential)

        # Ensure the LargePersonGroup exists
        try:
            self.admin_client.large_person_group.get(self.group_id)
            print("✅ LargePersonGroup found.")
        except Exception:
            print("Creating LargePersonGroup for the first time...")
            self.admin_client.large_person_group.create(
                large_person_group_id=self.group_id,
                name="Classroom Group",
                recognition_model=FaceRecognitionModel.RECOGNITION04
            )
            print("✅ LargePersonGroup created successfully.")

    def add_person_to_group(self, name: str, image_bytes: bytes) -> str:
        """Registers a student's face and trains the model."""

        # 1. Create a Person entry in the group
        person = self.admin_client.large_person_group.create_person(
            large_person_group_id=self.group_id,
            name=name
        )
        print(f"Created person: {name} with ID: {person.person_id}")

        # 2. Attach their face photo
        self.admin_client.large_person_group.add_face(
            large_person_group_id=self.group_id,
            person_id=person.person_id,
            image_content=image_bytes,
            detection_model=FaceDetectionModel.DETECTION03
        )
        print(f"Face added for: {name}")

        # 3. Retrain the model so it learns this new face
        poller = self.admin_client.large_person_group.begin_train(self.group_id)
        poller.result()  # Wait for training to complete
        print("✅ Model trained successfully.")

        return str(person.person_id)

    def detect_faces(self, image_bytes: bytes) -> list:
        """Detects all faces in a group photo."""
        detected_faces = self.face_client.detect(
            image_content=image_bytes,
            detection_model=FaceDetectionModel.DETECTION03,
            recognition_model=FaceRecognitionModel.RECOGNITION04,
            return_face_id=True
        )
        print(f"Detected {len(detected_faces)} faces in the photo.")
        return [str(face.face_id) for face in detected_faces]

    def identify_faces(self, face_ids: list) -> list:
        """Matches face IDs against all registered students."""
        if not face_ids:
            return []

        results = self.face_client.identify_from_large_person_group(
            face_ids=face_ids,
            large_person_group_id=self.group_id
        )

        identified = []
        for result in results:
            if result.candidates:
                best = result.candidates[0]
                if best.confidence > 0.6:  # Only accept 60%+ confident matches
                    identified.append({
                        "azure_person_id": str(best.person_id),
                        "confidence": best.confidence
                    })
        print(f"Identified {len(identified)} students.")
        return identified
