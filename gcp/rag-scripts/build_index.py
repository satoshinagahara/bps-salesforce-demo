"""
BigQuery dataset / tables / vector index の作成（冪等）。

作成対象:
  - dataset: bps_rag (asia-northeast1)
  - table:   documents  ドキュメントマスタ
  - table:   chunks     本体（embedding 保持）
  - vector index: chunks_embedding_idx  (COSINE, IVF)

使い方:
  python gcp/rag-scripts/build_index.py
"""
from __future__ import annotations

import sys

from google.cloud import bigquery
from google.cloud.exceptions import NotFound

PROJECT = "ageless-lamp-251200"
LOCATION = "asia-northeast1"
DATASET_ID = "bps_rag"
EMBEDDING_DIM = 768  # text-multilingual-embedding-002


def ensure_dataset(client: bigquery.Client) -> None:
    dataset_ref = bigquery.DatasetReference(PROJECT, DATASET_ID)
    try:
        client.get_dataset(dataset_ref)
        print(f"[skip] dataset already exists: {PROJECT}.{DATASET_ID}")
    except NotFound:
        dataset = bigquery.Dataset(dataset_ref)
        dataset.location = LOCATION
        dataset.description = "RAG index for BPS product specs & diagrams"
        client.create_dataset(dataset)
        print(f"[created] dataset: {PROJECT}.{DATASET_ID} ({LOCATION})")


def ensure_documents_table(client: bigquery.Client) -> None:
    table_id = f"{PROJECT}.{DATASET_ID}.documents"
    schema = [
        bigquery.SchemaField("document_id", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("product_keywords", "STRING", mode="REPEATED"),
        bigquery.SchemaField("product_display_name", "STRING"),
        bigquery.SchemaField("spec_gcs_path", "STRING"),
        bigquery.SchemaField("spec_markdown_path", "STRING"),
        bigquery.SchemaField("diagram_gcs_paths", "STRING", mode="REPEATED"),
        bigquery.SchemaField("figure_section_ranges", "JSON",
                             description="図面ごとの関連セクション番号リスト (例: {'fig1': ['3.1','3.2',...]})"),
        bigquery.SchemaField("ingested_at", "TIMESTAMP"),
    ]
    try:
        client.get_table(table_id)
        print(f"[skip] table already exists: {table_id}")
    except NotFound:
        table = bigquery.Table(table_id, schema=schema)
        client.create_table(table)
        print(f"[created] table: {table_id}")


def ensure_chunks_table(client: bigquery.Client) -> None:
    table_id = f"{PROJECT}.{DATASET_ID}.chunks"
    schema = [
        bigquery.SchemaField("chunk_id", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("document_id", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("doc_type", "STRING", mode="REQUIRED",
                             description="spec or figure"),
        bigquery.SchemaField("section", "STRING",
                             description="例: 3.2 (specのみ)"),
        bigquery.SchemaField("section_title", "STRING"),
        bigquery.SchemaField("page", "INT64",
                             description="例: 3 (specのみ)"),
        bigquery.SchemaField("figure_id", "STRING",
                             description="figureのみ (例: fig1)"),
        bigquery.SchemaField("figure_title", "STRING"),
        bigquery.SchemaField("related_figure_ids", "STRING", mode="REPEATED"),
        bigquery.SchemaField("related_sections", "STRING", mode="REPEATED"),
        bigquery.SchemaField("text", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("char_count", "INT64"),
        bigquery.SchemaField("embedding", "FLOAT64", mode="REPEATED",
                             description=f"{EMBEDDING_DIM} dims"),
        bigquery.SchemaField("embedding_model", "STRING"),
        bigquery.SchemaField("ingested_at", "TIMESTAMP"),
    ]
    try:
        client.get_table(table_id)
        print(f"[skip] table already exists: {table_id}")
    except NotFound:
        table = bigquery.Table(table_id, schema=schema)
        client.create_table(table)
        print(f"[created] table: {table_id}")


def ensure_vector_index(client: bigquery.Client) -> None:
    """VECTOR INDEX を作成。BQ の VECTOR INDEX は CREATE VECTOR INDEX ... IF NOT EXISTS 構文が使える。

    なお BQ の VECTOR_SEARCH は INDEX 無しでも実行可能（ブルートフォース）。
    数十チャンクでは INDEX の恩恵は誤差レベルだが、本番っぽさを出す意図で張っておく。
    """
    query = f"""
    CREATE VECTOR INDEX IF NOT EXISTS chunks_embedding_idx
    ON `{PROJECT}.{DATASET_ID}.chunks`(embedding)
    OPTIONS(index_type='IVF', distance_type='COSINE')
    """
    job = client.query(query)
    job.result()
    print("[ensured] vector index: chunks_embedding_idx (IVF/COSINE)")


def main() -> int:
    client = bigquery.Client(project=PROJECT, location=LOCATION)
    ensure_dataset(client)
    ensure_documents_table(client)
    ensure_chunks_table(client)
    # VECTOR INDEX はデータ0行ではエラーになるので、投入後に別途実行
    # 本スクリプトではスキーマだけ作り、INDEXは ingest.py 末尾で作る方針
    print("[done] schema ready. run ingest.py next.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
