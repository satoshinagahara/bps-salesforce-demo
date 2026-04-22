"""RAG サブシステム: Vertex AI Embeddings + BigQuery Vector Search によるリトリーブ。"""
from .retriever import retrieve_spec_chunks, get_document_asset_paths

__all__ = ["retrieve_spec_chunks", "get_document_asset_paths"]
