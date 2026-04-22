"""
BigQuery Vector Search + メタデータ展開によるチャンクリトリーブ。

公開関数:
  - retrieve_spec_chunks(query, product_filter=None, top_k=5)
  - get_document_asset_paths(document_id)
"""
from __future__ import annotations

import logging
import os
from typing import Any

import vertexai
from google.cloud import bigquery
from vertexai.language_models import TextEmbeddingInput, TextEmbeddingModel

log = logging.getLogger("rag.retriever")

GCP_PROJECT = os.environ.get("GCP_PROJECT", "ageless-lamp-251200")
BQ_LOCATION = os.environ.get("BQ_LOCATION", "asia-northeast1")
VERTEX_LOCATION = os.environ.get("VERTEX_LOCATION", "us-central1")
DATASET_ID = os.environ.get("RAG_DATASET", "bps_rag")
EMBEDDING_MODEL_ID = os.environ.get("RAG_EMBEDDING_MODEL", "text-multilingual-embedding-002")

_bq_client: bigquery.Client | None = None
_embedding_model: TextEmbeddingModel | None = None


def _get_bq_client() -> bigquery.Client:
    global _bq_client
    if _bq_client is None:
        _bq_client = bigquery.Client(project=GCP_PROJECT, location=BQ_LOCATION)
    return _bq_client


def _get_embedding_model() -> TextEmbeddingModel:
    global _embedding_model
    if _embedding_model is None:
        vertexai.init(project=GCP_PROJECT, location=VERTEX_LOCATION)
        _embedding_model = TextEmbeddingModel.from_pretrained(EMBEDDING_MODEL_ID)
    return _embedding_model


def _embed_query(text: str) -> list[float]:
    model = _get_embedding_model()
    result = model.get_embeddings([TextEmbeddingInput(text=text, task_type="RETRIEVAL_QUERY")])
    return list(result[0].values)


def retrieve_spec_chunks(
    query: str,
    product_filter: str | None = None,
    top_k: int = 5,
) -> dict:
    """BigQuery Vector Search で関連チャンクを取得し、related_figure_ids に基づく図面展開を同梱する。

    Args:
      query: 検索クエリテキスト（施策のWhy/What/Target + ニーズの統合文字列など）
      product_filter: 'a1000' / 'e2000' / None。document_id で絞り込む
      top_k: 上位取得件数

    Returns:
      {
        "chunks": [{chunk_id, doc_type, document_id, section, page, section_title,
                    figure_id, figure_title, text, distance, related_figure_ids}, ...],
        "expanded_figures": [{chunk_id, figure_id, figure_title, text, related_sections}, ...],
        "query_length": int,
      }
    """
    client = _get_bq_client()
    query_emb = _embed_query(query)

    # ベース検索: product_filter 指定時は document_id で絞る
    # BQ VECTOR_SEARCH は WHERE clause でのプレフィルタリングを options={'fraction_lists_to_search':1.0} + 'filter' で可能だが、
    # 小規模データでは outer WHERE で十分。brute-force モードでは全件スキャン後フィルタ。
    if product_filter:
        sql = f"""
        WITH search AS (
          SELECT base.*, distance
          FROM VECTOR_SEARCH(
            (SELECT * FROM `{GCP_PROJECT}.{DATASET_ID}.chunks`
             WHERE document_id = @product_filter),
            'embedding',
            (SELECT @query_embedding AS embedding),
            top_k => @top_k,
            distance_type => 'COSINE'
          )
        )
        SELECT chunk_id, document_id, doc_type, section, section_title, page,
               figure_id, figure_title, text, distance,
               related_figure_ids, related_sections
        FROM search
        ORDER BY distance ASC
        """
        params = [
            bigquery.ScalarQueryParameter("product_filter", "STRING", product_filter),
            bigquery.ArrayQueryParameter("query_embedding", "FLOAT64", query_emb),
            bigquery.ScalarQueryParameter("top_k", "INT64", top_k),
        ]
    else:
        sql = f"""
        SELECT base.chunk_id, base.document_id, base.doc_type, base.section,
               base.section_title, base.page, base.figure_id, base.figure_title,
               base.text, distance, base.related_figure_ids, base.related_sections
        FROM VECTOR_SEARCH(
          TABLE `{GCP_PROJECT}.{DATASET_ID}.chunks`,
          'embedding',
          (SELECT @query_embedding AS embedding),
          top_k => @top_k,
          distance_type => 'COSINE'
        )
        ORDER BY distance ASC
        """
        params = [
            bigquery.ArrayQueryParameter("query_embedding", "FLOAT64", query_emb),
            bigquery.ScalarQueryParameter("top_k", "INT64", top_k),
        ]

    job = client.query(sql, job_config=bigquery.QueryJobConfig(query_parameters=params))
    hit_rows = list(job.result())

    chunks = []
    figure_ids_to_expand: set[tuple[str, str]] = set()  # (document_id, figure_id)

    for r in hit_rows:
        c = {
            "chunk_id": r.chunk_id,
            "document_id": r.document_id,
            "doc_type": r.doc_type,
            "section": r.section,
            "section_title": r.section_title,
            "page": r.page,
            "figure_id": r.figure_id,
            "figure_title": r.figure_title,
            "text": r.text,
            "distance": round(float(r.distance), 4),
            "related_figure_ids": list(r.related_figure_ids) if r.related_figure_ids else [],
            "related_sections": list(r.related_sections) if r.related_sections else [],
        }
        chunks.append(c)
        # spec hit の関連図面を展開対象に追加
        if r.doc_type == "spec" and r.related_figure_ids:
            for fid in r.related_figure_ids:
                figure_ids_to_expand.add((r.document_id, fid))

    # 既にヒット済みの figure chunk は展開対象から除外
    already_hit = {(c["document_id"], c["figure_id"]) for c in chunks
                   if c["doc_type"] == "figure" and c["figure_id"]}
    figure_ids_to_expand -= already_hit

    expanded_figures = []
    if figure_ids_to_expand:
        # (doc_id, figure_id) 複合キーで SELECT
        pairs = list(figure_ids_to_expand)
        doc_ids = list({p[0] for p in pairs})
        fig_ids = list({p[1] for p in pairs})
        exp_sql = f"""
        SELECT chunk_id, document_id, figure_id, figure_title, text, related_sections
        FROM `{GCP_PROJECT}.{DATASET_ID}.chunks`
        WHERE doc_type = 'figure'
          AND document_id IN UNNEST(@doc_ids)
          AND figure_id IN UNNEST(@fig_ids)
        """
        exp_job = client.query(exp_sql, job_config=bigquery.QueryJobConfig(query_parameters=[
            bigquery.ArrayQueryParameter("doc_ids", "STRING", doc_ids),
            bigquery.ArrayQueryParameter("fig_ids", "STRING", fig_ids),
        ]))
        for r in exp_job.result():
            # pairs に含まれる組み合わせだけを採用（異なる doc の同名 figure_id を誤って取り込まないため）
            if (r.document_id, r.figure_id) not in figure_ids_to_expand:
                continue
            expanded_figures.append({
                "chunk_id": r.chunk_id,
                "document_id": r.document_id,
                "figure_id": r.figure_id,
                "figure_title": r.figure_title,
                "text": r.text,
                "related_sections": list(r.related_sections) if r.related_sections else [],
            })

    log.info(
        "[rag] retrieve: query_len=%d filter=%s top_k=%d hits=%d expanded=%d",
        len(query), product_filter, top_k, len(chunks), len(expanded_figures),
    )

    return {
        "chunks": chunks,
        "expanded_figures": expanded_figures,
        "query_length": len(query),
    }


def get_document_asset_paths(document_id: str) -> dict:
    """documents マスタから原本 GCS パスを引き、LWC プレビュー用のメタ情報を返す。

    Returns:
      {
        "document_id": str,
        "product_display_name": str,
        "spec_gcs_path": str,
        "diagram_gcs_paths": [str, ...],
      }
      見つからない場合は {"error": "..."}
    """
    client = _get_bq_client()
    sql = f"""
    SELECT document_id, product_display_name, spec_gcs_path, diagram_gcs_paths
    FROM `{GCP_PROJECT}.{DATASET_ID}.documents`
    WHERE document_id = @document_id
    LIMIT 1
    """
    job = client.query(sql, job_config=bigquery.QueryJobConfig(query_parameters=[
        bigquery.ScalarQueryParameter("document_id", "STRING", document_id),
    ]))
    rows = list(job.result())
    if not rows:
        return {"error": f"document_id not found: {document_id}"}
    r = rows[0]
    return {
        "document_id": r.document_id,
        "product_display_name": r.product_display_name,
        "spec_gcs_path": r.spec_gcs_path,
        "diagram_gcs_paths": list(r.diagram_gcs_paths) if r.diagram_gcs_paths else [],
    }
