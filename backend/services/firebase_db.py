import firebase_admin
from firebase_admin import credentials
from firebase_admin import firestore

class FirebaseDBService:
    def __init__(self, credentials_path: str):
        self.credentials_path = credentials_path
        
        # Connect to Firebase using your secret JSON key
        cred = credentials.Certificate(self.credentials_path)
        
        # Prevent initializing twice if the server restarts
        if not firebase_admin._apps:
            firebase_admin.initialize_app(cred)
            
        # Get a reference to the database
        self.db = firestore.client()

    def add_student(self, name: str, reg_number: str, face_id: str):
        # Save a new student to the 'students' collection
        doc_ref = self.db.collection('students').document(reg_number)
        doc_ref.set({
            'name': name,
            'reg_number': reg_number,
            'face_id': face_id
        })
        return True

    def get_all_students(self):
        # Fetch all registered students
        students = self.db.collection('students').stream()
        return [doc.to_dict() for doc in students]

    def delete_student(self, reg_number: str):
        # Delete a student from the 'students' collection
        self.db.collection('students').document(reg_number).delete()
        return True

    def log_attendance(self, present_reg_numbers: list):
        from datetime import datetime
        # Create a document for today's date
        today = datetime.now().strftime("%Y-%m-%d")
        log_ref = self.db.collection('attendance_logs').document(today)
        
        # Save the list of present students without overwriting previous ones
        log_ref.set({
            'date': today,
            'timestamp': firestore.SERVER_TIMESTAMP
        }, merge=True)
        log_ref.update({
            'present_students': firestore.ArrayUnion(present_reg_numbers)
        })
        return True
