"""
図面PNG (2枚) を Gemini 2.5 Flash で構造化テキスト記述に変換し、
<name>.caption.md としてローカル + GCS の両方に保存する。

使い方:
  python gcp/rag-scripts/caption_diagrams.py
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import vertexai
from google.cloud import storage
from vertexai.generative_models import GenerativeModel, Part

PROJECT = "ageless-lamp-251200"
VERTEX_LOCATION = "us-central1"
VERTEX_MODEL = "gemini-2.5-flash"
GCS_BUCKET = "bps-design-assets"

REPO_ROOT = Path(__file__).resolve().parents[2]
DIAGRAMS_DIR = REPO_ROOT / "gcp" / "assets" / "diagrams"

# 図面ごとのコンテキスト（品質向上のため、製品脈絡をプロンプトに含める）
DIAGRAMS = [
    {
        "local_png": "blade_pitch_control_diagram.png",
        "gcs_png": "diagrams/blade_pitch_control_diagram.png",
        "product": "A-1000 大型風力タービン（BPS Corporation、定格出力5MW、ローター径150m）",
        "topic": "ブレードピッチ制御機構",
        "context": (
            "この図面は、ブレード根元部（ハブ内蔵）に配置される電動ピッチモータと"
            "ブレードの角度制御機構を示す配置図である。制御目的は発電効率最大化"
            "（部分負荷モード 5〜12 m/s）と突風時の負荷低減・出力平滑化。"
        ),
    },
    {
        "local_png": "e2000_bms_architecture.png",
        "gcs_png": "diagrams/e2000_bms_architecture.png",
        "product": "E-2000 EnerCharge Pro 蓄電システム（BPS Corporation、定格容量500kWh、LFPセル）",
        "topic": "BMS（バッテリー管理システム）3階層アーキテクチャ",
        "context": (
            "この図面は、CMU（セル監視）→ BMU（モジュール制御）→ SBMS（システム全体制御）"
            "の3階層BMS構成を示す。強制空冷式、動作温度-10〜+45℃、通常運転モード"
            "は-10〜+35℃、高温注意モードは35〜45℃（出力75%制限）。"
        ),
    },
]

PROMPT_TEMPLATE = """\
あなたは製品仕様書に付属する技術図面を、検索インデックス用のテキスト記述に変換する専門家です。

【対象製品】 {product}
【図面トピック】 {topic}
【コンテキスト】 {context}

以下の観点で、この図面の内容を**800〜1500文字程度**の構造化テキストに書き起こしてください。

1. **構成要素の識別**: 図に描かれている部品・モジュール・ブロックを列挙し、配置関係を記述する
2. **信号・データの流れ**: 矢印・接続線が示す信号の方向と意味を説明する
3. **仕様書との対応**: 製品仕様書のどのセクション（制御モード、アーキテクチャ、メンテナンス等）と関連するかを明示する
4. **技術的含意**: この図面から読み取れる設計思想・既知制約・拡張可能性
5. **検索用キーワード**: 末尾に「## キーワード」セクションを設け、この図面がヒットすべきクエリ語を10個以上列挙する

## 出力形式
Markdownで記述してください。見出し構造（##）を使って整理し、冒頭に1行の要約（summary）を入れてください。
前後に注釈・コードフェンス・余計な説明は付けないでください。

## 注意
- 図中に明示的に描かれていない内容は書かないでください（推測・捏造禁止）
- 「〜と思われる」「〜の可能性」のような曖昧表現は避けてください
"""


def generate_caption(model: GenerativeModel, png_bytes: bytes, item: dict) -> str:
    prompt = PROMPT_TEMPLATE.format(
        product=item["product"],
        topic=item["topic"],
        context=item["context"],
    )
    image_part = Part.from_data(data=png_bytes, mime_type="image/png")
    response = model.generate_content(
        [prompt, image_part],
        generation_config={"temperature": 0.2, "max_output_tokens": 4096},
    )
    return response.text.strip()


def save_locally(output_path: Path, text: str) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(text, encoding="utf-8")
    print(f"  [local] {output_path.relative_to(REPO_ROOT)}")


def upload_to_gcs(storage_client: storage.Client, gcs_object: str, text: str) -> None:
    bucket = storage_client.bucket(GCS_BUCKET)
    blob = bucket.blob(gcs_object)
    blob.upload_from_string(text, content_type="text/markdown; charset=utf-8")
    print(f"  [gcs]   gs://{GCS_BUCKET}/{gcs_object}")


def main() -> int:
    vertexai.init(project=PROJECT, location=VERTEX_LOCATION)
    model = GenerativeModel(VERTEX_MODEL)
    storage_client = storage.Client(project=PROJECT)

    for item in DIAGRAMS:
        local_png = DIAGRAMS_DIR / item["local_png"]
        if not local_png.exists():
            print(f"[skip] not found: {local_png}")
            continue

        caption_name = local_png.stem + ".caption.md"
        caption_local = DIAGRAMS_DIR / caption_name
        caption_gcs = item["gcs_png"].replace(".png", ".caption.md")

        if caption_local.exists() and os.environ.get("FORCE_REGEN") != "1":
            print(f"[skip] exists: {caption_local.relative_to(REPO_ROOT)} (FORCE_REGEN=1 to overwrite)")
            continue

        print(f"[captioning] {item['local_png']}  (topic: {item['topic']})")
        png_bytes = local_png.read_bytes()
        caption = generate_caption(model, png_bytes, item)
        save_locally(caption_local, caption)
        upload_to_gcs(storage_client, caption_gcs, caption)

    print("[done] diagram captioning complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
