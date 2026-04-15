"""
Vertex AI Imagen で製品画像を生成してGCSにアップロードするスクリプト。
"""
import base64
import json
import subprocess
from pathlib import Path

import requests

PROJECT_ID = "ageless-lamp-251200"
LOCATION = "us-central1"
MODEL = "imagen-3.0-generate-002"
GCS_BUCKET = "bps-design-assets"

OUT_DIR = Path(__file__).parent
OUT_DIR.mkdir(exist_ok=True)

IMAGES = [
    {
        "name": "enercharge_pro_e2000.png",
        "gcs_path": "products/enercharge_pro_e2000.png",
        "prompt": (
            "A professional product photograph of a large industrial battery energy storage system "
            "in a white 20-foot shipping container, installed at a factory facility. "
            "The container has visible cooling vents and 'BPS EnerCharge Pro' branding text. "
            "Surrounded by concrete ground and industrial plant buildings. "
            "Clear blue sky, daylight, realistic photography style, corporate product shot."
        ),
        "aspect": "16:9",
    },
    {
        "name": "a1000_wind_turbine.png",
        "gcs_path": "products/a1000_wind_turbine.png",
        "prompt": (
            "A professional product photograph of a large 5MW class industrial wind turbine with "
            "three white blades, tall steel tower, at a wind farm in a mountainous inland area. "
            "The nacelle has 'BPS A-1000' branding. "
            "Clear blue sky with some clouds, daylight, realistic photography style, "
            "corporate product shot from slightly below angle."
        ),
        "aspect": "16:9",
    },
]


def get_access_token() -> str:
    result = subprocess.run(
        ["gcloud", "auth", "print-access-token"],
        capture_output=True, text=True, check=True,
        env={"CLOUDSDK_PYTHON": "/opt/homebrew/bin/python3.12", "PATH": "/opt/homebrew/bin:/usr/bin:/bin"},
    )
    return result.stdout.strip()


def generate_image(prompt: str, aspect: str) -> bytes:
    url = f"https://{LOCATION}-aiplatform.googleapis.com/v1/projects/{PROJECT_ID}/locations/{LOCATION}/publishers/google/models/{MODEL}:predict"
    headers = {
        "Authorization": f"Bearer {get_access_token()}",
        "Content-Type": "application/json",
    }
    body = {
        "instances": [{"prompt": prompt}],
        "parameters": {
            "sampleCount": 1,
            "aspectRatio": aspect,
            "personGeneration": "dont_allow",
            "safetySetting": "block_only_high",
        },
    }
    resp = requests.post(url, headers=headers, json=body, timeout=120)
    resp.raise_for_status()
    data = resp.json()
    pred = data["predictions"][0]
    return base64.b64decode(pred["bytesBase64Encoded"])


def upload_to_gcs(local_path: Path, gcs_path: str):
    subprocess.run(
        ["gcloud", "storage", "cp", str(local_path), f"gs://{GCS_BUCKET}/{gcs_path}",
         "--project", PROJECT_ID],
        check=True,
        env={"CLOUDSDK_PYTHON": "/opt/homebrew/bin/python3.12", "PATH": "/opt/homebrew/bin:/usr/bin:/bin"},
    )


def main():
    for img in IMAGES:
        print(f"Generating: {img['name']}")
        png = generate_image(img["prompt"], img["aspect"])
        local = OUT_DIR / img["name"]
        local.write_bytes(png)
        print(f"  saved: {local} ({len(png)} bytes)")
        upload_to_gcs(local, img["gcs_path"])
        print(f"  uploaded: gs://{GCS_BUCKET}/{img['gcs_path']}")


if __name__ == "__main__":
    main()
