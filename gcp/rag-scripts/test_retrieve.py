"""
VECTOR_SEARCH の動作確認。いくつかの代表クエリで上位ヒットを表示する。

使い方:
  python gcp/rag-scripts/test_retrieve.py
  python gcp/rag-scripts/test_retrieve.py "任意のクエリ"
"""
from __future__ import annotations

import sys

import vertexai
from google.cloud import bigquery
from vertexai.language_models import TextEmbeddingInput, TextEmbeddingModel

PROJECT = "ageless-lamp-251200"
BQ_LOCATION = "asia-northeast1"
VERTEX_LOCATION = "us-central1"
DATASET_ID = "bps_rag"
EMBEDDING_MODEL_ID = "text-multilingual-embedding-002"

DEFAULT_QUERIES = [
    "低風速域 3.5-5m/s での発電効率改善",
    "高温環境でのリチウムイオン電池の寿命劣化",
    "ブレードピッチ制御機構の部品構成",
    "BMS の温度管理とセルバランシング",
    "タイの工場での蓄電システム運用課題",
    "内陸山間部の風力発電所における起動トルク",
]

TOP_K = 5


def embed_query(query: str) -> list[float]:
    vertexai.init(project=PROJECT, location=VERTEX_LOCATION)
    model = TextEmbeddingModel.from_pretrained(EMBEDDING_MODEL_ID)
    emb = model.get_embeddings([TextEmbeddingInput(text=query, task_type="RETRIEVAL_QUERY")])
    return list(emb[0].values)


def run_vector_search(client: bigquery.Client, query_embedding: list[float], top_k: int = TOP_K):
    sql = f"""
    SELECT
      base.chunk_id,
      base.document_id,
      base.doc_type,
      base.section,
      base.section_title,
      base.figure_title,
      base.related_figure_ids,
      distance
    FROM VECTOR_SEARCH(
      TABLE `{PROJECT}.{DATASET_ID}.chunks`,
      'embedding',
      (SELECT @query_embedding AS embedding),
      top_k => @top_k,
      distance_type => 'COSINE'
    )
    ORDER BY distance ASC
    """
    job = client.query(
        sql,
        job_config=bigquery.QueryJobConfig(
            query_parameters=[
                bigquery.ArrayQueryParameter("query_embedding", "FLOAT64", query_embedding),
                bigquery.ScalarQueryParameter("top_k", "INT64", top_k),
            ],
        ),
    )
    return list(job.result())


def print_results(query: str, rows) -> None:
    print(f"\n▼ query: {query}")
    print("-" * 80)
    for i, r in enumerate(rows, 1):
        label = r.section_title if r.doc_type == "spec" else r.figure_title
        sec = f"§{r.section}" if r.section else f"[{r.figure_id if hasattr(r, 'figure_id') else r.doc_type}]"
        related = f" related_figs={list(r.related_figure_ids)}" if r.related_figure_ids else ""
        print(f"  {i}. dist={r.distance:.4f}  {r.document_id}/{r.doc_type} {sec}  {label}{related}")


def main(argv: list[str]) -> int:
    queries = argv[1:] if len(argv) > 1 else DEFAULT_QUERIES
    client = bigquery.Client(project=PROJECT, location=BQ_LOCATION)
    for q in queries:
        emb = embed_query(q)
        rows = run_vector_search(client, emb, top_k=TOP_K)
        print_results(q, rows)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
