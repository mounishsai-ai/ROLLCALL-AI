"""
Download the AdaFace IR-50 pretrained model from HuggingFace.

Usage:
    python download_model.py

This downloads the AdaFace IR-50 checkpoint (~250MB) trained on MS1MV2
from HuggingFace to the pretrained/ directory.
"""

import os
import sys


def download_adaface_model(target_dir="pretrained"):
    """Download the AdaFace IR-50 checkpoint from HuggingFace."""
    os.makedirs(target_dir, exist_ok=True)
    target_path = os.path.join(target_dir, "adaface_ir50_ms1mv2.ckpt")

    if os.path.exists(target_path):
        size_mb = os.path.getsize(target_path) / (1024 * 1024)
        print(f"[OK] Model already exists: {target_path} ({size_mb:.1f} MB)")
        return target_path

    print("[INFO] Downloading AdaFace IR-50 model from HuggingFace...")
    print("[INFO] This is a one-time download (~250 MB)...")

    try:
        from huggingface_hub import hf_hub_download

        path = hf_hub_download(
            repo_id="VishalMishraTss/AdaFace",
            filename="adaface_ir50_ms1mv2.ckpt",
            local_dir=target_dir,
        )
        size_mb = os.path.getsize(path) / (1024 * 1024)
        print(f"[OK] Downloaded AdaFace model: {path} ({size_mb:.1f} MB)")
        return path

    except ImportError:
        print("[ERROR] huggingface_hub is not installed.")
        print("        Run: pip install huggingface_hub")
        print(f"        Or manually download the model to: {target_path}")
        print("        From: https://huggingface.co/VishalMishraTss/AdaFace/resolve/main/adaface_ir50_ms1mv2.ckpt")
        sys.exit(1)
    except Exception as e:
        print(f"[ERROR] Failed to download model: {e}")
        print(f"        Manually download to: {target_path}")
        print("        From: https://huggingface.co/VishalMishraTss/AdaFace/resolve/main/adaface_ir50_ms1mv2.ckpt")
        sys.exit(1)


if __name__ == "__main__":
    download_adaface_model()
