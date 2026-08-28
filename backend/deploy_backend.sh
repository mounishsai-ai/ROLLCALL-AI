#!/bin/bash
gcloud run deploy attendance-backend \
  --source=. \
  --project=smart-attendance-37133 \
  --region=us-central1 \
  --allow-unauthenticated \
  --execution-environment=gen2 \
  --memory=4Gi \
  --cpu=2 \
  --timeout=300 \
  --min-instances=0 \
  --max-instances=3 \
  --add-volume=name=known-faces,type=cloud-storage,bucket=smart-attendance-37133-known-faces \
  --add-volume-mount=volume=known-faces,mount-path=/app/known_faces \
  --set-env-vars="FIREBASE_CREDENTIALS_PATH=/secrets/serviceAccountKey.json,KNOWN_FACES_DIR=/app/known_faces,FACE_RECOGNITION_BACKEND=adaface,DEEPFACE_MATCH_THRESHOLD=0.40,DEEPFACE_UNSURE_THRESHOLD=0.35,ADAFACE_MODEL_PATH=pretrained/adaface_ir50_ms1mv2.ckpt,ADAFACE_ARCHITECTURE=ir_50,VERTEX_PROJECT=smart-attendance-37133,VERTEX_LOCATION=global" \
  --set-secrets="GEMINI_API_KEY=gemini-api-key:latest,/secrets/serviceAccountKey.json=firebase-service-account:latest"
