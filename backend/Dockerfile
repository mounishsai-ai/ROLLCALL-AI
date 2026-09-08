FROM python:3.11-slim

# opencv/deepface need these at runtime even though we never touch a display.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgl1 \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV KMP_DUPLICATE_LIB_OK=TRUE \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/app/pretrained/.cache

# PyTorch's default PyPI wheel bundles CUDA — roughly 2.5GB of GPU drivers for
# a container that has no GPU. Installing the CPU build first means the line
# below finds torch already satisfied and skips it. This is the difference
# between a ~1GB image and a ~4GB one, and it comes straight off cold-start time.
RUN pip install --no-cache-dir \
    --index-url https://download.pytorch.org/whl/cpu \
    torch torchvision

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY download_model.py .
RUN python download_model.py

# Bakes RetinaFace's own weights into the image so the first request in a
# fresh instance doesn't pay for a runtime download on top of everything else.
RUN python -c "from deepface import DeepFace; import numpy as np; \
DeepFace.extract_faces(np.zeros((160,160,3), dtype='uint8'), detector_backend='retinaface', enforce_detection=False)"

COPY main.py sync_faces.py ./
COPY services/ services/

EXPOSE 8080
CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT:-8080}"]
