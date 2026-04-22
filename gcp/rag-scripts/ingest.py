"""
Markdown原本 + 図面キャプション → チャンク化 → Vertex AI Embeddings → BigQuery 投入。

処理対象:
  - gcp/assets/specs/*.md (セクション単位で分割)
  - gcp/assets/diagrams/*.caption.md (1図面=1チャンク)

本スクリプトは**冪等ではない**（再実行すると重複INSERTになる）。
再実行する場合は事前に `TRUNCATE TABLE bps_rag.chunks` を手動で実行すること。

使い方:
  python gcp/rag-scripts/ingest.py
"""
from __future__ import annotations

import json
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import vertexai
from google.cloud import bigquery
from vertexai.language_models import TextEmbeddingInput, TextEmbeddingModel

PROJECT = "ageless-lamp-251200"
BQ_LOCATION = "asia-northeast1"
VERTEX_LOCATION = "us-central1"  # embeddings も us-central1 で使える（Vertexの共通モデル）
DATASET_ID = "bps_rag"
EMBEDDING_MODEL_ID = "text-multilingual-embedding-002"

REPO_ROOT = Path(__file__).resolve().parents[2]
SPECS_DIR = REPO_ROOT / "gcp" / "assets" / "specs"
DIAGRAMS_DIR = REPO_ROOT / "gcp" / "assets" / "diagrams"

# ============================================================
# ドキュメントマスタ定義
# ============================================================

DOCUMENTS = [
    {
        "document_id": "a1000",
        "product_display_name": "A-1000 大型風力タービン",
        "product_keywords": ["A-1000", "風力タービン", "タービン", "Wind Turbine", "風力"],
        "spec_markdown_path": "gcp/assets/specs/bps_spec_wind_turbine_a1000.md",
        "spec_gcs_path": "specs/bps_spec_wind_turbine_a1000.pdf",
        "diagrams": [
            {
                "figure_id": "fig1",
                "figure_title": "ブレードピッチ制御機構 配置図",
                "local_png": "blade_pitch_control_diagram.png",
                "gcs_png": "diagrams/blade_pitch_control_diagram.png",
                "caption_local": "blade_pitch_control_diagram.caption.md",
                "related_sections": ["3.1", "3.2", "3.3", "3.4", "3.5"],
            },
        ],
    },
    {
        "document_id": "e2000",
        "product_display_name": "E-2000 EnerCharge Pro 蓄電システム",
        "product_keywords": ["E-2000", "EnerCharge", "蓄電", "バッテリー", "Battery", "蓄電池"],
        "spec_markdown_path": "gcp/assets/specs/bps_spec_battery_e2000.md",
        "spec_gcs_path": "specs/bps_spec_battery_e2000.pdf",
        "diagrams": [
            {
                "figure_id": "fig1",
                "figure_title": "BMS 3階層アーキテクチャ図",
                "local_png": "e2000_bms_architecture.png",
                "gcs_png": "diagrams/e2000_bms_architecture.png",
                "caption_local": "e2000_bms_architecture.caption.md",
                "related_sections": ["2.2", "3.1", "3.2", "3.3", "3.4", "3.5"],
            },
        ],
    },
]

# ============================================================
# Markdown パース
# ============================================================

FRONTMATTER_RE = re.compile(r"^---\n.*?\n---\n", re.DOTALL)
COVER_RE = re.compile(r'<div class="cover">.*?</div>', re.DOTALL)
PAGEBREAK_RE = re.compile(r'<div class="pagebreak"></div>')
PAGE_HEADER_RE = re.compile(r"^# P\.(\d+)\s+(.+?)\s*$")
SECTION_HEADER_RE = re.compile(r"^## (\d+\.\d+)\s+(.+?)\s*$")
FOOTER_RE = re.compile(r"^---\s*$")


def parse_sections(md_path: Path) -> list[dict]:
    """Markdownを `## x.x` 単位に分割する。

    Returns:
      list of {section, section_title, page, text}
    """
    text = md_path.read_text(encoding="utf-8")
    text = FRONTMATTER_RE.sub("", text)
    text = COVER_RE.sub("", text)
    text = PAGEBREAK_RE.sub("", text)

    chunks: list[dict] = []
    current_page: int | None = None
    current_section: str | None = None
    current_title: str | None = None
    buffer: list[str] = []

    def flush() -> None:
        nonlocal buffer
        if current_section is not None:
            body = "\n".join(buffer).strip()
            if body:
                chunks.append({
                    "section": current_section,
                    "section_title": current_title,
                    "page": current_page,
                    "text": body,
                })
        buffer = []

    for raw_line in text.split("\n"):
        line = raw_line.rstrip()

        # 末尾の "---" 以降（footerの斜体行）は無視
        if FOOTER_RE.match(line) and current_section is not None:
            flush()
            current_section = None
            continue

        page_m = PAGE_HEADER_RE.match(line)
        if page_m:
            flush()
            current_page = int(page_m.group(1))
            current_section = None
            continue

        section_m = SECTION_HEADER_RE.match(line)
        if section_m:
            flush()
            current_section = section_m.group(1)
            current_title = section_m.group(2).strip()
            buffer = [line]  # セクションヘッダ自体はテキストに含める
            continue

        buffer.append(line)

    flush()
    return chunks


# ============================================================
# Chunk 生成
# ============================================================

def build_chunks(documents: list[dict]) -> list[dict]:
    """全ドキュメントから chunks を生成する。embedding はこの段階では未設定。"""
    now = datetime.now(timezone.utc)
    all_chunks: list[dict] = []

    for doc in documents:
        doc_id = doc["document_id"]
        md_path = REPO_ROOT / doc["spec_markdown_path"]
        sections = parse_sections(md_path)
        print(f"[{doc_id}] parsed {len(sections)} sections from {md_path.name}")

        # 図面 → 関連セクションの逆引きを作成
        figure_lookup: dict[str, list[str]] = {}  # section -> [figure_id, ...]
        for fig in doc["diagrams"]:
            for sec in fig["related_sections"]:
                figure_lookup.setdefault(sec, []).append(fig["figure_id"])

        # spec chunks
        for s in sections:
            related_figs = figure_lookup.get(s["section"], [])
            chunk_id = f"{doc_id}::spec::sec{s['section']}"
            all_chunks.append({
                "chunk_id": chunk_id,
                "document_id": doc_id,
                "doc_type": "spec",
                "section": s["section"],
                "section_title": s["section_title"],
                "page": s["page"],
                "figure_id": None,
                "figure_title": None,
                "related_figure_ids": related_figs,
                "related_sections": [],
                "text": s["text"],
                "char_count": len(s["text"]),
                "ingested_at": now.isoformat(),
            })

        # figure chunks
        for fig in doc["diagrams"]:
            caption_path = DIAGRAMS_DIR / fig["caption_local"]
            caption = caption_path.read_text(encoding="utf-8").strip()
            # section_title に figure_title を含めて検索ヒット性向上
            chunk_text = f"# {fig['figure_title']}\n\n{caption}"
            chunk_id = f"{doc_id}::figure::{fig['figure_id']}"
            all_chunks.append({
                "chunk_id": chunk_id,
                "document_id": doc_id,
                "doc_type": "figure",
                "section": None,
                "section_title": None,
                "page": None,
                "figure_id": fig["figure_id"],
                "figure_title": fig["figure_title"],
                "related_figure_ids": [],
                "related_sections": list(fig["related_sections"]),
                "text": chunk_text,
                "char_count": len(chunk_text),
                "ingested_at": now.isoformat(),
            })

    return all_chunks


# ============================================================
# Embedding 生成
# ============================================================

def generate_embeddings(chunks: list[dict]) -> None:
    """chunks 各要素に embedding / embedding_model を追加する（in-place）。"""
    vertexai.init(project=PROJECT, location=VERTEX_LOCATION)
    model = TextEmbeddingModel.from_pretrained(EMBEDDING_MODEL_ID)

    # バッチ処理（API limit対策: 最大5件/batchが推奨）
    BATCH = 5
    for i in range(0, len(chunks), BATCH):
        batch = chunks[i:i + BATCH]
        inputs = [TextEmbeddingInput(text=c["text"], task_type="RETRIEVAL_DOCUMENT")
                  for c in batch]
        t0 = time.time()
        result = model.get_embeddings(inputs)
        elapsed = time.time() - t0
        for c, emb in zip(batch, result):
            c["embedding"] = list(emb.values)
            c["embedding_model"] = EMBEDDING_MODEL_ID
        print(f"[embed] batch {i//BATCH + 1}: {len(batch)} chunks in {elapsed:.2f}s "
              f"(dim={len(result[0].values)})")


# ============================================================
# BigQuery 投入
# ============================================================

def insert_documents_master(client: bigquery.Client, documents: list[dict]) -> None:
    table_id = f"{PROJECT}.{DATASET_ID}.documents"
    # 既存を全削除して再投入（documents はマスタ的な性格なのでTRUNCATE相当でOK）
    client.query(f"TRUNCATE TABLE `{table_id}`").result()

    rows = []
    for d in documents:
        rows.append({
            "document_id": d["document_id"],
            "product_keywords": d["product_keywords"],
            "product_display_name": d["product_display_name"],
            "spec_gcs_path": d["spec_gcs_path"],
            "spec_markdown_path": d["spec_markdown_path"],
            "diagram_gcs_paths": [f["gcs_png"] for f in d["diagrams"]],
            "figure_section_ranges": json.dumps({
                f["figure_id"]: f["related_sections"] for f in d["diagrams"]
            }, ensure_ascii=False),
            "ingested_at": datetime.now(timezone.utc).isoformat(),
        })
    errors = client.insert_rows_json(table_id, rows)
    if errors:
        raise RuntimeError(f"insert_rows_json errors: {errors}")
    print(f"[bq] inserted {len(rows)} rows into documents")


def insert_chunks(client: bigquery.Client, chunks: list[dict]) -> None:
    table_id = f"{PROJECT}.{DATASET_ID}.chunks"
    client.query(f"TRUNCATE TABLE `{table_id}`").result()

    rows = []
    for c in chunks:
        rows.append({
            "chunk_id": c["chunk_id"],
            "document_id": c["document_id"],
            "doc_type": c["doc_type"],
            "section": c["section"],
            "section_title": c["section_title"],
            "page": c["page"],
            "figure_id": c["figure_id"],
            "figure_title": c["figure_title"],
            "related_figure_ids": c["related_figure_ids"],
            "related_sections": c["related_sections"],
            "text": c["text"],
            "char_count": c["char_count"],
            "embedding": c["embedding"],
            "embedding_model": c["embedding_model"],
            "ingested_at": c["ingested_at"],
        })
    errors = client.insert_rows_json(table_id, rows)
    if errors:
        raise RuntimeError(f"insert_rows_json errors: {errors}")
    print(f"[bq] inserted {len(rows)} rows into chunks")


def create_vector_index(client: bigquery.Client) -> None:
    """投入後に VECTOR INDEX を作成（BQはデータ0件だとINDEX作成エラーになる）。"""
    query = f"""
    CREATE VECTOR INDEX IF NOT EXISTS chunks_embedding_idx
    ON `{PROJECT}.{DATASET_ID}.chunks`(embedding)
    OPTIONS(index_type='IVF', distance_type='COSINE')
    """
    client.query(query).result()
    print("[bq] vector index ensured: chunks_embedding_idx")


# ============================================================
# Main
# ============================================================

def main() -> int:
    client = bigquery.Client(project=PROJECT, location=BQ_LOCATION)

    print("=== Step 1: Markdown → chunks ===")
    chunks = build_chunks(DOCUMENTS)
    print(f"total chunks: {len(chunks)}")
    for c in chunks:
        print(f"  {c['chunk_id']:<40} {c['char_count']:>5} chars  {c['section_title'] or c['figure_title'] or ''}")

    print("\n=== Step 2: Generate embeddings ===")
    generate_embeddings(chunks)

    print("\n=== Step 3: BigQuery insert ===")
    insert_documents_master(client, DOCUMENTS)
    insert_chunks(client, chunks)

    print("\n=== Step 4: Create vector index ===")
    # BQ の VECTOR INDEX は最低5000行以上必要（少量データでは INDEX 作成は skip される）
    # 数十行では自動的に brute-force になるのでINDEX作成は試みるだけ
    try:
        create_vector_index(client)
    except Exception as e:
        print(f"[warn] vector index creation skipped/failed: {e}")
        print("       → brute-force VECTOR_SEARCH will still work on small data.")

    print("\n[done] ingest complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
