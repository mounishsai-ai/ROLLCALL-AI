# Deploy the attendance backend to Cloud Run.
#
# PowerShell, not bash, and deliberately so: Git Bash on Windows rewrites
# anything shaped like a Unix path into a Windows one, so the container paths
# below ("/secrets/...", "/app/known_faces") arrive mangled and the deploy is
# rejected with "should be a valid unix absolute path". PowerShell passes them
# through untouched.
#
# 8Gi because BOTH recognition backends are loaded: TensorFlow (RetinaFace +
# ArcFace) and PyTorch (AdaFace) in one process. That is what lets a single
# registration reach both indexes, so switching FACE_RECOGNITION_BACKEND never
# leaves a student unrecognisable.
#
# Three settings here are not tuning knobs:
#
#   -no-cpu-throttling
#     THE AGENTIC SCAN DOES NOT WORK WITHOUT THIS. By default Cloud Run only
#     gives a container CPU while it is handling a request, and throttles it to
#     near zero the rest of the time. Our whole design returns a job id in
#     milliseconds and does the real work on a background thread afterwards -
#     which is exactly the situation that default starves. Observed: a scan
#     emitted its first trace event at 0.00s and then made no progress at all
#     for over ten minutes. It does not error, it just stops, which is the
#     worst way for it to fail. Always-allocated CPU costs more per instance-
#     second but is not optional here.
#
#   -max-instances 1
#     The live reasoning trace is held in the server's memory (job_store.py).
#     A scan uploads to one instance and is then polled for; with a second
#     instance the poll can land on a copy that never heard of that job and
#     answers 404. Cloud Run's session affinity is best-effort and does NOT fix
#     this. One instance does. To go wider, jobs must move into Firestore first.
#
#   -min-instances 0
#     Scale to zero: costs nothing while idle. The trade is that a sleeping
#     container must load TensorFlow, PyTorch and the AdaFace checkpoint before
#     it answers - over two minutes, landing on whoever takes the first photo.
#
#     >>> ON EXPO DAY: change to 1 that morning, back to 0 afterwards. <<<
#     One warm instance is roughly $40-50/month of credits. Or, for free, take
#     one throwaway scan a few minutes before presenting - same effect.
#
# One-time prerequisites:
#   gcloud secrets create attendance-api-key --data-file=<file with the key>
#   gcloud secrets create firebase-service-account --data-file=serviceAccountKey.json
#   ...and grant the Cloud Run runtime service account secretAccessor on each.
#
# When writing the key file, emit NO trailing newline. A Windows text-mode
# write puts "\r\n" on the end; gcloud strips the "\n" and keeps the "\r", and
# the key then works in a header (curl trims it) but produces a malformed URL
# for the "?key=" image requests - which fails client-side, before any request
# is sent, and looks like the server is down. Write it in binary:
#   python -c "import secrets,sys; sys.stdout.buffer.write(secrets.token_urlsafe(32).encode())" > key.bin

# Deliberately NOT "Stop". gcloud writes its normal progress to stderr, and
# Windows PowerShell 5.1 turns any stderr line from a native program into an
# error record - with ErrorActionPreference=Stop that aborts a deploy that is
# working perfectly well. Success is judged by $LASTEXITCODE instead, which is
# what the exit code is for.
$ErrorActionPreference = "Continue"

$PROJECT = "smart-attendance-37133"
$REGION  = "us-central1"
$SERVICE = "attendance-backend"

# This system spans TWO Google Cloud projects, which is easy to miss:
#   smart-attendance-37133   Cloud Run, Vertex AI, the photo bucket, secrets
#   ai-face-detector-daaad   the Firebase project - Firestore and Hosting
# The service account key bridges them, which is why Firestore works from here
# at all. Hosting therefore lives under the Firebase project, and so does the
# origin the browser will call from - getting this wrong blocks every request
# with a CORS error that looks like the backend is down.
$FIREBASE_PROJECT = "ai-face-detector-daaad"
$ORIGINS = "https://$FIREBASE_PROJECT.web.app,https://$FIREBASE_PROJECT.firebaseapp.com"

# Commas separate variables by default, and ALLOWED_ORIGINS contains one, so
# "^@^" tells gcloud to split on @ instead.
$ENVVARS = "^@^" + (@(
  "FIREBASE_CREDENTIALS_PATH=/secrets/serviceAccountKey.json",
  "KNOWN_FACES_DIR=/app/known_faces",
  "FACE_RECOGNITION_BACKEND=adaface",
  "DEEPFACE_MATCH_THRESHOLD=0.40",
  "DEEPFACE_UNSURE_THRESHOLD=0.35",
  "FACE_MATCH_MARGIN=0.05",
  "ADAFACE_MODEL_PATH=pretrained/adaface_ir50_ms1mv2.ckpt",
  "ADAFACE_ARCHITECTURE=ir_50",
  "VERTEX_PROJECT=$PROJECT",
  "VERTEX_LOCATION=global",
  "ALLOWED_ORIGINS=$ORIGINS"
) -join "@")

$SECRETS = @(
  "API_KEY=attendance-api-key:latest",
  "GEMINI_API_KEY=gemini-api-key:latest",
  "/secrets/serviceAccountKey.json=firebase-service-account:latest"
) -join ","

gcloud run deploy $SERVICE `
  --source=. `
  --project=$PROJECT `
  --region=$REGION `
  --allow-unauthenticated `
  --quiet `
  --execution-environment=gen2 `
  --memory=8Gi `
  --cpu=2 `
  --timeout=300 `
  --min-instances=0 `
  --max-instances=1 `
  --cpu-boost `
  --no-cpu-throttling `
  --add-volume="name=known-faces,type=cloud-storage,bucket=$PROJECT-known-faces" `
  --add-volume-mount="volume=known-faces,mount-path=/app/known_faces" `
  --set-env-vars=$ENVVARS `
  --set-secrets=$SECRETS

if ($LASTEXITCODE -ne 0) { throw "Deploy failed." }

$url = gcloud run services describe $SERVICE --project=$PROJECT --region=$REGION --format="value(status.url)"
Write-Output ""
Write-Output "Deployed: $url"
Write-Output ""
Write-Output "Retrieve the access key with:"
Write-Output "  gcloud secrets versions access latest --secret=attendance-api-key --project=$PROJECT"
