"""Google OAuth 2.0 (Installed App Flow) - Calendar + Gmail 用。

初回実行時のみブラウザで同意を求め、以降は refresh_token で自動更新。

使用方法（初回セットアップ）:
    uv run python -m mcp_clients.google_auth

※ このモジュールは既存 GCP 実装 (Cloud Functions/Vertex AI 等) からは完全に独立しており、
   新規 OAuth client + 新規 token.json を使用する。
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Iterable

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow

DEFAULT_SCOPES = [
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/gmail.compose",
]


def get_credentials(
    credentials_path: str | os.PathLike,
    token_path: str | os.PathLike,
    scopes: Iterable[str] = DEFAULT_SCOPES,
) -> Credentials:
    """Credentials を取得。token がなければ InstalledAppFlow を起動する。"""
    scopes = list(scopes)
    token_path = Path(token_path)
    creds: Credentials | None = None

    if token_path.exists():
        creds = Credentials.from_authorized_user_file(str(token_path), scopes)

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            flow = InstalledAppFlow.from_client_secrets_file(str(credentials_path), scopes)
            creds = flow.run_local_server(port=0)
        token_path.parent.mkdir(parents=True, exist_ok=True)
        token_path.write_text(creds.to_json())
        print(f"✅ Saved token to {token_path}")

    return creds


if __name__ == "__main__":
    # Smoke test / 初回セットアップ
    root = Path(__file__).resolve().parents[1]
    cred_path = Path(os.environ.get(
        "GOOGLE_OAUTH_CREDENTIALS",
        root / "config" / "tokens" / "google_credentials.json",
    ))
    token_path = Path(os.environ.get(
        "GOOGLE_OAUTH_TOKEN",
        root / "config" / "tokens" / "google_token.json",
    ))
    if not cred_path.exists():
        print(f"❌ credentials.json not found at: {cred_path}")
        print("   GCP Console → APIs & Services → Credentials → Create OAuth client ID (Desktop app) → Download JSON")
        print(f"   Place it at: {cred_path}")
        raise SystemExit(1)

    creds = get_credentials(cred_path, token_path)
    print(f"✅ Credentials valid: {creds.valid}, scopes: {creds.scopes}")
