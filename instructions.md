# Quick Run Instructions

This is the short operational runbook. For architecture and data-flow details, see `system_design.md`.

python -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload

## Prerequisites

- Python 3.11
- Flutter SDK
- Firebase service-account JSON
- AdaFace checkpoint when using AdaFace
- Laptop and phone on the same Wi-Fi when testing on a physical phone

## Backend setup

```powershell
cd "C:\worksapce\AI FACE DETECTION FROM GROUP PHOTO\backend"
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

If the AdaFace checkpoint is missing:

```powershell
python download_model.py
```

Create `backend/.env` from `.env.example` and set at least:

```dotenv
FIREBASE_CREDENTIALS_PATH=serviceAccountKey.json
KNOWN_FACES_DIR=known_faces
FACE_RECOGNITION_BACKEND=adaface
DEEPFACE_MATCH_THRESHOLD=0.60
DEEPFACE_UNSURE_THRESHOLD=0.45
FACE_MATCH_MARGIN=0.05
ADAFACE_MODEL_PATH=pretrained/adaface_ir50_ms1mv2.ckpt
ADAFACE_ARCHITECTURE=ir_50
```

Run commands from the `backend` directory so relative paths resolve correctly.

## Start the backend

```powershell
cd "C:\worksapce\AI FACE DETECTION FROM GROUP PHOTO\backend"
.\.venv\Scripts\Activate.ps1
python -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

For a normal run without auto-reload:

```powershell
python -m uvicorn main:app --host 0.0.0.0 --port 8000
```

Check that it is running:

```powershell
Invoke-RestMethod http://127.0.0.1:8000/
Invoke-RestMethod http://127.0.0.1:8000/students
```

Stop the backend with `Ctrl+C`.

## Start the frontend

In a second terminal:

```powershell
cd "C:\worksapce\AI FACE DETECTION FROM GROUP PHOTO\frontend"
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

For a physical phone, replace the URL with the laptop Wi-Fi IP:

```powershell
flutter run --release --dart-define=API_BASE_URL=http://<LAPTOP_WIFI_IP>:8000
```

Other common URLs:

```text
Flutter web on laptop: http://127.0.0.1:8000
Android emulator:      http://10.0.2.2:8000
Physical phone:        http://<LAPTOP_WIFI_IP>:8000
```

The app’s Server Settings can also be used to save the backend URL. Allow port `8000` through Windows Firewall when using another device.

## Switch backend

Stop the backend first, edit `backend/.env`, and choose one:

```dotenv
FACE_RECOGNITION_BACKEND=arcface
```

or:

```dotenv
FACE_RECOGNITION_BACKEND=adaface
```

Then ensure the selected backend has embeddings and restart Uvicorn. Only one backend is active per API process; ArcFace and AdaFace indexes are separate.

## Sync missing embeddings

With the desired backend selected and the API stopped:

```powershell
cd "C:\worksapce\AI FACE DETECTION FROM GROUP PHOTO\backend"
.\.venv\Scripts\Activate.ps1
python sync_faces.py
```

This reads students from Firebase and adds only students missing from the selected FAISS index. It does not refresh existing embeddings.

## Rebuild a backend index

Stop the API, select the backend in `.env`, then run:

```powershell
python sync_faces.py --rebuild-local
```

This uses local images only and does not contact Firebase. Rebuild after changing alignment, preprocessing, model files, or an existing registration image. Every registration image must contain exactly one detectable face.

To rebuild both backends, run the command once with `FACE_RECOGNITION_BACKEND=arcface`, then switch to `adaface` and run it again.

## Registration rules

- Register one person per image.
- Wait until the active backend status is completed before taking attendance.
- A new registration updates only the currently active backend.
- Run sync/rebuild separately if the student must be available in the other backend.
- If a face is rejected, replace the image with a clear single-face photo and rebuild/sync again.

## Basic troubleshooting

- Backend startup failure: check Firebase credentials, `.env`, Python version, and AdaFace checkpoint path.
- Frontend cannot connect: check the API URL, port `8000`, network, and Windows Firewall.
- Manage Students stops loading during attendance: the current CPU recognition call can block the FastAPI event loop until the scan finishes; restart the backend if it remains stuck.
- Everyone is absent after a model or alignment change: rebuild the selected backend index instead of only lowering thresholds.

## Stop everything

- Backend: press `Ctrl+C` in the backend terminal.
- Flutter: press `q` in the Flutter terminal or close the Chrome test window.