"""
ローカル動作確認用: main.py の _call_gemini を直接呼ぶ。
gunicorn/functions-framework を経由しないので fork 問題を回避できる。
"""
import json
import os
import sys
from pathlib import Path

os.environ.setdefault("GCP_PROJECT", "ageless-lamp-251200")
os.environ.setdefault("VERTEX_LOCATION", "us-central1")
os.environ.setdefault("VERTEX_MODEL", "gemini-2.5-flash")
os.environ.setdefault("GCS_BUCKET", "bps-design-assets")

sys.path.insert(0, str(Path(__file__).parent))
from main import _call_gemini  # noqa: E402


def main() -> None:
    with open(Path(__file__).parent / "test_request.json", encoding="utf-8") as f:
        req = json.load(f)
    print(f"Calling Gemini with model={os.environ['VERTEX_MODEL']}...")
    result = _call_gemini(req)
    print("\n=== Gemini response ===")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
