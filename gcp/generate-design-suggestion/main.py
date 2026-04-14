"""
Cloud Functions Gen2 entry point: generate-design-suggestion

GCS から仕様書PDFと図面PNGを取得 → Vertex AI Gemini マルチモーダル処理
→ 構造化JSON生成 → Salesforce DesignSuggestion__c に書き戻し
"""
from __future__ import annotations

import base64
import json
import logging
import os
import re
import time
import uuid
from datetime import datetime, timezone

import functions_framework
import jwt
import requests as http_requests
import vertexai
from google.cloud import storage
from vertexai.generative_models import GenerativeModel, Part

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("generate-design-suggestion")

GCP_PROJECT = os.environ.get("GCP_PROJECT", "ageless-lamp-251200")
VERTEX_LOCATION = os.environ.get("VERTEX_LOCATION", "us-central1")
VERTEX_MODEL = os.environ.get("VERTEX_MODEL", "gemini-2.5-flash")
GCS_BUCKET = os.environ.get("GCS_BUCKET", "bps-design-assets")

PRODUCT_ASSETS = {
    "A-1000": {
        "keywords": ["A-1000", "風力タービン", "タービン", "Wind Turbine"],
        "spec": "specs/bps_spec_wind_turbine_a1000.pdf",
        "diagram": "diagrams/blade_pitch_control_diagram.png",
    },
    "E-2000": {
        "keywords": ["E-2000", "EnerCharge", "蓄電", "バッテリー", "Battery"],
        "spec": "specs/bps_spec_battery_e2000.pdf",
        "diagram": "diagrams/e2000_bms_architecture.png",
    },
}
DEFAULT_PRODUCT_KEY = "A-1000"

SF_LOGIN_URL = os.environ.get("SF_LOGIN_URL", "https://login.salesforce.com")
SF_CONSUMER_KEY = os.environ.get("SF_CONSUMER_KEY", "")
SF_USERNAME = os.environ.get("SF_USERNAME", "")
SF_PRIVATE_KEY_B64 = os.environ.get("SF_PRIVATE_KEY_B64", "")
SF_INSTANCE_URL = os.environ.get("SF_INSTANCE_URL", "")
SF_ACCESS_TOKEN = os.environ.get("SF_ACCESS_TOKEN", "")

_storage_client: storage.Client | None = None
_model: GenerativeModel | None = None


def _get_storage_client() -> storage.Client:
    global _storage_client
    if _storage_client is None:
        _storage_client = storage.Client(project=GCP_PROJECT)
    return _storage_client


def _get_model() -> GenerativeModel:
    global _model
    if _model is None:
        vertexai.init(project=GCP_PROJECT, location=VERTEX_LOCATION)
        _model = GenerativeModel(VERTEX_MODEL)
    return _model


def _fetch_gcs_bytes(bucket_name: str, object_name: str) -> bytes:
    log.info("fetching gs://%s/%s", bucket_name, object_name)
    bucket = _get_storage_client().bucket(bucket_name)
    blob = bucket.blob(object_name)
    return blob.download_as_bytes()


SYSTEM_PROMPT = """\
あなたは再生可能エネルギー機器メーカー BPS Corporation の製品設計アドバイザーです。
営業が収集した顧客ニーズと、添付の製品仕様書PDFおよび図面画像を照合し、
具体的な製品エンハンス提案を生成してください。

以下のルールを厳守してください：
1. 出力は必ず1つの有効なJSONオブジェクトのみ。配列ではなくオブジェクト。前後に説明文・マークダウンコードブロック・注釈を一切含めない。複数のニーズが入力されても、総合的に判断して1つの提案にまとめること。
2. キーは英語、値は日本語で記述する。
3. suggestionText は3〜5文。具体的な部品名・制御仕様・数値を仕様書から引用する。
4. referenceSpec には仕様書のセクション番号とページ相当の記述を含める（例: "P.3 §3.2 制御モード表"）。
5. priority は「高」「中」「低」のいずれか。顧客影響度が大きいほど高。

出力フォーマット：
{
  "targetProduct": "対象製品名",
  "targetComponent": "対象コンポーネント名",
  "suggestionText": "設計示唆本文（3〜5文）",
  "referenceSpec": "参照した仕様書の該当箇所",
  "referenceDiagram": "参照した図面ファイル名",
  "priority": "高"
}
"""


def _build_user_prompt(req: dict) -> str:
    parts = [
        "以下の製品施策と関連する顧客ニーズに対して、添付の仕様書PDFと図面画像を必ず参照した上で、"
        "どの製品のどの部分をどう改善すべきかを提案してください。\n",
        f"\n【製品施策タイトル】{req.get('initiativeTitle', req.get('title', ''))}",
        f"\n【対象製品】{req.get('productName', '(不明)')}",
    ]
    if req.get("whyRationale"):
        parts.append(f"\n【Why（なぜやるか）】{req['whyRationale']}")
    if req.get("whatDescription"):
        parts.append(f"\n【What（何をするか）】{req['whatDescription']}")
    if req.get("targetCustomer"):
        parts.append(f"\n【ターゲット顧客像】{req['targetCustomer']}")

    linked_needs = req.get("linkedNeeds", [])
    if linked_needs:
        parts.append(f"\n\n--- 紐付く顧客ニーズ（{len(linked_needs)}件） ---")
        for i, need in enumerate(linked_needs, 1):
            parts.append(f"\n[ニーズ{i}] {need.get('title', '')}")
            if need.get("customerVoice"):
                parts.append(f"  顧客の声: {need['customerVoice']}")
            if need.get("accountName"):
                parts.append(f"  顧客: {need['accountName']}")
    else:
        if req.get("customerVoice"):
            parts.append(f"\n【顧客の声】{req['customerVoice']}")
        if req.get("description"):
            parts.append(f"\n【詳細】{req['description']}")

    return "\n".join(parts)


def _parse_model_response(raw: str) -> dict:
    """Gemini応答をJSONにパース。配列・コードブロック混入に耐性を持たせる。"""
    text = raw.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```\s*$", "", text)
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        match = re.search(r"[\[{].*[}\]]", text, re.DOTALL)
        if match:
            parsed = json.loads(match.group(0))
        else:
            raise
    if isinstance(parsed, list):
        return parsed[0] if parsed else {}
    return parsed


_SA_EMAIL = os.environ.get("SA_EMAIL", "bps-demo-sa@ageless-lamp-251200.iam.gserviceaccount.com")


def _generate_signed_urls(req: dict) -> dict:
    """GCS オブジェクトの Signed URL を生成（1時間有効）。IAM signBlob API を使用。"""
    import google.auth
    from google.auth.transport import requests as auth_requests

    try:
        credentials, _ = google.auth.default()
        if hasattr(credentials, "refresh"):
            credentials.refresh(auth_requests.Request())

        spec_object, diagram_object = _resolve_product_assets(req)
        client = _get_storage_client()
        bucket = client.bucket(GCS_BUCKET)
        urls = {}
        for key, obj_name in [("specUrl", spec_object), ("diagramUrl", diagram_object)]:
            blob = bucket.blob(obj_name)
            url = blob.generate_signed_url(
                version="v4",
                expiration=3600,
                method="GET",
                service_account_email=_SA_EMAIL,
                access_token=credentials.token,
            )
            urls[key] = url
            log.info("signed URL generated for %s", obj_name)
        return urls
    except Exception as e:
        log.warning("signed URL generation failed: %s", e)
        return {}


def _resolve_product_assets(req: dict) -> tuple[str, str]:
    """製品名からGCSオブジェクトパスを解決する。キーワードマッチング。"""
    product_name = req.get("productName", "")
    for key, assets in PRODUCT_ASSETS.items():
        for keyword in assets["keywords"]:
            if keyword in product_name:
                log.info("product matched: '%s' contains '%s' → %s", product_name, keyword, key)
                return assets["spec"], assets["diagram"]
    log.info("no product match for '%s', using default %s", product_name, DEFAULT_PRODUCT_KEY)
    default = PRODUCT_ASSETS[DEFAULT_PRODUCT_KEY]
    return default["spec"], default["diagram"]


def _call_gemini(req: dict) -> dict:
    spec_object, diagram_object = _resolve_product_assets(req)
    pdf_bytes = _fetch_gcs_bytes(GCS_BUCKET, spec_object)
    png_bytes = _fetch_gcs_bytes(GCS_BUCKET, diagram_object)

    pdf_part = Part.from_data(data=pdf_bytes, mime_type="application/pdf")
    png_part = Part.from_data(data=png_bytes, mime_type="image/png")

    model = _get_model()
    response = model.generate_content(
        [SYSTEM_PROMPT, _build_user_prompt(req), pdf_part, png_part],
        generation_config={
            "temperature": 0.2,
            "max_output_tokens": 8192,
            "response_mime_type": "application/json",
        },
    )
    raw_text = response.text
    log.info("gemini response length: %d chars", len(raw_text))
    try:
        return _parse_model_response(raw_text)
    except Exception as e:
        log.error("gemini JSON parse failed. raw response (first 1000 chars): %s", raw_text[:1000])
        raise


def _call_gemini_text(system_prompt: str, user_prompt: str, temperature: float = 0.2) -> str:
    """テキストのみのGemini呼出。429エラー時はリトライ。"""
    model = _get_model()
    for attempt in range(3):
        try:
            response = model.generate_content(
                [system_prompt, user_prompt],
                generation_config={
                    "temperature": temperature,
                    "max_output_tokens": 8192,
                },
            )
            log.info("gemini text response length: %d chars", len(response.text))
            return response.text
        except Exception as e:
            if "429" in str(e) and attempt < 2:
                wait = (attempt + 1) * 5
                log.warning("429 rate limit, retrying in %ds (attempt %d/3)", wait, attempt + 1)
                time.sleep(wait)
            else:
                raise


def _handle_prompt(request):
    """汎用プロンプトエンドポイント: systemPrompt + context → Gemini → テキスト応答"""
    request_id = f"req_{uuid.uuid4().hex[:12]}"
    try:
        req = request.get_json(silent=True) or {}
    except Exception:
        return (json.dumps({"error": "invalid json"}), 400, _cors_headers())

    system_prompt = req.get("systemPrompt", "")
    context = req.get("context", "")
    temperature = float(req.get("temperature", 0.2))

    if not context:
        return (json.dumps({"error": "context is required"}), 400, _cors_headers())

    try:
        result_text = _call_gemini_text(system_prompt, context, temperature)
    except Exception as e:
        log.exception("[%s] gemini prompt call failed", request_id)
        return (json.dumps({"error": str(e), "requestId": request_id}), 500, _cors_headers())

    return (
        json.dumps({"text": result_text, "requestId": request_id}, ensure_ascii=False),
        200,
        _cors_headers(),
    )


def _handle_equipment_alert(request):
    """シナリオ2: IoT 設備異常イベント → Product Engineering Agent → SF書き戻し"""
    from product_engineering_agent import run_agent

    request_id = f"req_{uuid.uuid4().hex[:12]}"
    log.info("[%s] received equipment alert", request_id)

    try:
        payload = request.get_json(silent=True) or {}
    except Exception:
        return (json.dumps({"error": "invalid json"}), 400, _cors_headers())

    if not payload.get("assetId"):
        return (json.dumps({"error": "assetId required"}), 400, _cors_headers())

    try:
        sf_access_token, sf_instance_url = _get_sf_access_token()
    except Exception as e:
        log.exception("[%s] sf auth failed", request_id)
        return (json.dumps({"error": f"sf auth: {e}"}), 500, _cors_headers())

    try:
        result = run_agent(payload, sf_access_token, sf_instance_url, request_id)
    except Exception as e:
        log.exception("[%s] agent failed", request_id)
        return (json.dumps({"error": f"agent error: {e}", "requestId": request_id}), 500, _cors_headers())

    return (json.dumps({**result, "requestId": request_id}, ensure_ascii=False), 200, _cors_headers())


def _handle_trigger_html(request):
    """HTMLトリガーページ。シナリオ2のデモ用にIoTイベントを発火する画面"""
    html = _build_trigger_html()
    return (html, 200, {"Content-Type": "text/html; charset=utf-8"})


def _build_trigger_html() -> str:
    """シナリオ2用HTMLトリガーページのHTML文字列を返す"""
    return TRIGGER_HTML


@functions_framework.http
def generate_design_suggestion(request):
    request_id = f"req_{uuid.uuid4().hex[:12]}"

    if request.method == "OPTIONS":
        return ("", 204, _cors_headers())

    # GET /trigger → HTMLページを返す
    if request.method == "GET":
        path = request.path.rstrip("/")
        if path.endswith("/trigger"):
            return _handle_trigger_html(request)
        return (json.dumps({"error": "method not allowed"}), 405, _cors_headers())

    if request.method != "POST":
        return (json.dumps({"error": "method not allowed"}), 405, _cors_headers())

    # パスベースルーティング
    path = request.path.rstrip("/")
    if path.endswith("/prompt"):
        return _handle_prompt(request)
    if path.endswith("/equipment-alert"):
        return _handle_equipment_alert(request)

    log.info("[%s] received design suggestion request", request_id)

    try:
        req = request.get_json(silent=True) or {}
    except Exception as e:
        return (json.dumps({"error": f"invalid json: {e}"}), 400, _cors_headers())

    has_context = req.get("initiativeId") or req.get("needsCardId")
    missing = [] if has_context else ["initiativeId or needsCardId"]
    if not req.get("initiativeTitle") and not req.get("title"):
        missing.append("initiativeTitle or title")
    if missing:
        return (
            json.dumps({"error": f"missing required fields: {missing}"}),
            400,
            _cors_headers(),
        )

    try:
        parsed = _call_gemini(req)
    except Exception as e:
        log.exception("[%s] gemini call failed", request_id)
        return (json.dumps({"error": f"gemini error: {e}", "requestId": request_id}), 500, _cors_headers())

    result = {
        "designSuggestionId": None,
        "targetProduct": parsed.get("targetProduct", ""),
        "targetComponent": parsed.get("targetComponent", ""),
        "suggestionText": parsed.get("suggestionText", ""),
        "referenceSpec": parsed.get("referenceSpec", ""),
        "referenceDiagram": parsed.get("referenceDiagram", ""),
        "priority": parsed.get("priority", "中"),
        "processedBy": f"Vertex AI {VERTEX_MODEL}",
        "generatedAt": datetime.now(timezone.utc).astimezone().isoformat(),
        "gcpRequestId": request_id,
    }

    signed_urls = _generate_signed_urls(req)
    result["specUrl"] = signed_urls.get("specUrl", "")
    result["diagramUrl"] = signed_urls.get("diagramUrl", "")

    sf_record_id = _write_to_salesforce(result, req, request_id)
    result["designSuggestionId"] = sf_record_id

    log.info("[%s] success: %s / %s (sf_id=%s)", request_id, result["targetProduct"], result["targetComponent"], sf_record_id)
    return (json.dumps(result, ensure_ascii=False), 200, _cors_headers())


_sf_token_cache: dict = {}


def _get_sf_access_token() -> tuple[str, str]:
    """Salesforce アクセストークンを取得。JWT Bearer Flow または直指定。"""
    if SF_ACCESS_TOKEN:
        return SF_ACCESS_TOKEN, SF_INSTANCE_URL

    cache_key = "sf_token"
    cached = _sf_token_cache.get(cache_key)
    if cached and cached["expires_at"] > time.time():
        return cached["access_token"], cached["instance_url"]

    if not SF_PRIVATE_KEY_B64 or not SF_CONSUMER_KEY or not SF_USERNAME:
        raise RuntimeError("SF auth not configured: set SF_ACCESS_TOKEN or SF_PRIVATE_KEY_B64+SF_CONSUMER_KEY+SF_USERNAME")

    private_key = base64.b64decode(SF_PRIVATE_KEY_B64).decode("utf-8")
    now = int(time.time())
    payload = {
        "iss": SF_CONSUMER_KEY,
        "sub": SF_USERNAME,
        "aud": SF_LOGIN_URL,
        "exp": now + 300,
    }
    assertion = jwt.encode(payload, private_key, algorithm="RS256")
    resp = http_requests.post(
        f"{SF_LOGIN_URL}/services/oauth2/token",
        data={"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion},
        timeout=30,
    )
    resp.raise_for_status()
    token_data = resp.json()
    _sf_token_cache[cache_key] = {
        "access_token": token_data["access_token"],
        "instance_url": token_data["instance_url"],
        "expires_at": now + 7200,
    }
    log.info("SF JWT auth success, instance=%s", token_data["instance_url"])
    return token_data["access_token"], token_data["instance_url"]


def _write_to_salesforce(result: dict, req: dict, request_id: str) -> str | None:
    """DesignSuggestion__c レコードをSalesforceに作成し、レコードIDを返す。"""
    try:
        access_token, instance_url = _get_sf_access_token()
    except Exception as e:
        log.warning("[%s] SF auth failed, skipping writeback: %s", request_id, e)
        return None

    record = {
        "TargetProduct__c": result.get("targetProduct", ""),
        "TargetComponent__c": result.get("targetComponent", ""),
        "SuggestionText__c": result.get("suggestionText", ""),
        "ReferenceSpec__c": result.get("referenceSpec", ""),
        "ReferenceDiagram__c": result.get("referenceDiagram", ""),
        "Priority__c": result.get("priority", "中"),
        "ProcessedBy__c": result.get("processedBy", f"Vertex AI {VERTEX_MODEL}"),
        "GeneratedAt__c": datetime.now(timezone.utc).isoformat(),
        "GcpRequestId__c": request_id,
    }
    if req.get("initiativeId"):
        record["Initiative__c"] = req["initiativeId"]
    if req.get("needsCardId"):
        record["NeedsCard__c"] = req["needsCardId"]

    url = f"{instance_url}/services/data/v62.0/sobjects/DesignSuggestion__c"
    resp = http_requests.post(
        url,
        headers={"Authorization": f"Bearer {access_token}", "Content-Type": "application/json"},
        json=record,
        timeout=30,
    )
    if resp.status_code == 201:
        record_id = resp.json().get("id")
        log.info("[%s] SF writeback success: %s", request_id, record_id)
        return record_id
    else:
        log.error("[%s] SF writeback failed (%d): %s", request_id, resp.status_code, resp.text)
        return None


def _cors_headers() -> dict:
    return {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, X-API-Key",
        "Content-Type": "application/json; charset=utf-8",
    }


# ============================================================
# シナリオ2: HTMLトリガーページ
# ============================================================

DEMO_ASSET_E2000_ID = os.environ.get("DEMO_ASSET_E2000_ID", "02iIe00000165UeIAI")
DEMO_ASSET_A1000_ID = os.environ.get("DEMO_ASSET_A1000_ID", "02iIe00000165VhIAI")
_TRIGGER_HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>BPS 設備監視シミュレーター</title>
<style>
  body {
    font-family: 'Hiragino Sans', 'Yu Gothic', sans-serif;
    background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
    color: #fff;
    margin: 0; padding: 24px 0;
    min-height: 100vh;
  }
  .container {
    background: rgba(255,255,255,0.05);
    border: 1px solid rgba(255,255,255,0.1);
    border-radius: 12px;
    padding: 36px 48px;
    max-width: 720px;
    width: 90%;
    margin: 0 auto;
    box-shadow: 0 20px 60px rgba(0,0,0,0.4);
  }
  h1 { margin: 0 0 8px; font-size: 22px; letter-spacing: 0.05em; }
  .subtitle { color: #9ca3af; font-size: 13px; margin-bottom: 28px; }
  .scenario {
    background: #0f172a;
    border: 1px solid #334155;
    border-radius: 8px;
    padding: 18px 22px;
    margin-bottom: 18px;
  }
  .scenario-header {
    display: flex; justify-content: space-between; align-items: center;
    margin-bottom: 14px;
  }
  .scenario-title { font-size: 15px; font-weight: 700; color: #e2e8f0; }
  .scenario-tag {
    font-size: 10px; letter-spacing: 0.1em;
    background: rgba(96,165,250,0.15); color: #60a5fa;
    padding: 3px 8px; border-radius: 3px;
  }
  .row {
    display: flex; justify-content: space-between;
    padding: 6px 0; font-size: 13px;
  }
  .row-label { color: #94a3b8; }
  .row-value { color: #e2e8f0; font-weight: 600; }
  .sensor-value {
    font-size: 22px; color: #f59e0b; font-weight: 700;
  }
  .threshold { color: #64748b; font-size: 13px; font-weight: normal; margin-left: 6px; }
  .btn {
    width: 100%;
    padding: 12px; margin-top: 12px;
    font-size: 14px; font-weight: 600;
    background: #ea580c; color: white;
    border: none; border-radius: 6px;
    cursor: pointer; letter-spacing: 0.04em;
    transition: all 0.2s;
  }
  .btn:hover { background: #c2410c; }
  .btn:disabled { background: #64748b; cursor: not-allowed; }
  .pipeline { margin-top: 20px; font-size: 12px; color: #94a3b8; text-align: center; }
  .pipeline strong { color: #60a5fa; }
  .status {
    margin-top: 20px; padding: 14px;
    background: #0f172a; border-radius: 6px;
    font-size: 12px; color: #e2e8f0;
    min-height: 24px; white-space: pre-wrap;
    font-family: monospace;
  }
  .status.ok { border-left: 4px solid #10b981; }
  .status.err { border-left: 4px solid #ef4444; }

  .input-row {
    margin: 12px 0;
    padding: 10px 12px;
    background: rgba(255,255,255,0.03);
    border-radius: 6px;
  }
  .input-label {
    display: block;
    font-size: 11px;
    color: #94a3b8;
    margin-bottom: 8px;
    letter-spacing: 0.05em;
  }
  .input-pair { display: flex; align-items: center; gap: 8px; }
  .input-num {
    width: 80px;
    padding: 6px 10px;
    background: #0f172a;
    border: 1px solid #475569;
    border-radius: 4px;
    color: #f59e0b;
    font-size: 16px;
    font-weight: 700;
    text-align: right;
    font-family: monospace;
  }
  .input-num:focus {
    outline: none;
    border-color: #ea580c;
  }
  .input-sep { color: #64748b; font-size: 12px; }
  .input-unit { color: #94a3b8; font-size: 12px; }

  /* progress steps */
  .progress-section {
    margin-top: 16px;
    padding: 14px 18px;
    background: #0f172a;
    border: 1px solid #1e3a8a;
    border-radius: 6px;
  }
  .progress-title {
    font-size: 11px;
    color: #60a5fa;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    margin-bottom: 10px;
  }
  .progress-step {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 5px 0;
    font-size: 12px;
    color: #64748b;
    transition: all 0.3s;
  }
  .progress-step.current {
    color: #93c5fd;
    font-weight: 600;
  }
  .progress-step.done {
    color: #6ee7b7;
  }
  .step-icon {
    display: inline-block;
    width: 18px;
    height: 18px;
    text-align: center;
    font-weight: 700;
  }
  .progress-step.current .step-icon {
    animation: spin 1s linear infinite;
    display: inline-block;
  }
  @keyframes spin { to { transform: rotate(360deg); } }

  /* tool history */
  .tool-history {
    margin-top: 16px;
    padding: 14px 18px;
    background: #0f172a;
    border: 1px solid #166534;
    border-radius: 6px;
  }
  .tool-history-title {
    font-size: 11px;
    color: #6ee7b7;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    margin-bottom: 10px;
  }
  .tool-row {
    display: grid;
    grid-template-columns: 22px 130px 1fr 1fr 50px;
    gap: 8px;
    align-items: center;
    padding: 5px 0;
    font-size: 11px;
    border-bottom: 1px dashed #1e293b;
    font-family: monospace;
  }
  .tool-row:last-child { border-bottom: none; }
  .tool-num { color: #64748b; }
  .tool-name { color: #93c5fd; font-weight: 700; }
  .tool-args { color: #cbd5e1; }
  .tool-result { color: #6ee7b7; }
  .tool-time { color: #94a3b8; text-align: right; }
</style>
</head>
<body>
<div class="container">
  <h1>⚡ BPS 設備監視シミュレーター</h1>
  <div class="subtitle">IoT センサーイベント発火デモ（複数シナリオ）</div>

  <!-- シナリオA: E-2000 -->
  <div class="scenario">
    <div class="scenario-header">
      <span class="scenario-title">シナリオA: 蓄電システム高温異常</span>
      <span class="scenario-tag">E-2000</span>
    </div>
    <div class="row"><span class="row-label">設備</span><span class="row-value">EnerCharge Pro #001 (Bangkok Plant B)</span></div>
    <div class="row"><span class="row-label">顧客</span><span class="row-value">東亜電子工業</span></div>
    <div class="input-row">
      <label class="input-label">センサー: セル温度</label>
      <div class="input-pair">
        <input type="number" step="0.1" id="value-e2000" value="47.5" class="input-num"/>
        <span class="input-sep">/ 閾値</span>
        <input type="number" step="0.1" id="threshold-e2000" value="45.0" class="input-num"/>
        <span class="input-unit">℃</span>
      </div>
    </div>
    <button class="btn" id="trigger-e2000" onclick="fireEvent('e2000')">⚠ 異常イベントを発火</button>
  </div>

  <!-- シナリオB: A-1000 -->
  <div class="scenario">
    <div class="scenario-header">
      <span class="scenario-title">シナリオB: 風力タービン振動異常</span>
      <span class="scenario-tag">A-1000</span>
    </div>
    <div class="row"><span class="row-label">設備</span><span class="row-value">A-1000 大型風力タービン #003 (中部第3拠点)</span></div>
    <div class="row"><span class="row-label">顧客</span><span class="row-value">アライドパワー株式会社</span></div>
    <div class="input-row">
      <label class="input-label">センサー: ブレード振動値</label>
      <div class="input-pair">
        <input type="number" step="0.1" id="value-a1000" value="8.7" class="input-num"/>
        <span class="input-sep">/ 閾値</span>
        <input type="number" step="0.1" id="threshold-a1000" value="7.0" class="input-num"/>
        <span class="input-unit">mm/s</span>
      </div>
    </div>
    <button class="btn" id="trigger-a1000" onclick="fireEvent('a1000')">⚠ 異常イベントを発火</button>
  </div>

  <!-- 進捗ステップ表示 -->
  <div class="progress-section" id="progress" style="display:none">
    <div class="progress-title">エージェント処理状況</div>
    <div class="progress-step" data-step="1">
      <span class="step-icon">⟳</span>
      <span class="step-text">イベントを Pub/Sub 経由で Cloud Functions に送信中...</span>
    </div>
    <div class="progress-step" data-step="2">
      <span class="step-icon">⟳</span>
      <span class="step-text">Salesforce から Asset 情報を取得中（get_asset_info）</span>
    </div>
    <div class="progress-step" data-step="3">
      <span class="step-icon">⟳</span>
      <span class="step-text">Cloud Storage から仕様書PDF・図面PNGを取得中</span>
    </div>
    <div class="progress-step" data-step="4">
      <span class="step-icon">⟳</span>
      <span class="step-text">Vertex AI Gemini が仕様書と照合し業務的解釈を生成中...</span>
    </div>
    <div class="progress-step" data-step="5">
      <span class="step-icon">⟳</span>
      <span class="step-text">Salesforce に Equipment_Alert__c レコードを書き戻し中</span>
    </div>
  </div>

  <!-- Tool呼出履歴 (完了後) -->
  <div class="tool-history" id="toolHistory" style="display:none">
    <div class="tool-history-title">Agent ツール呼出履歴 (実行ログ)</div>
    <div id="toolHistoryBody"></div>
  </div>

  <div class="pipeline">
    Pub/Sub → Cloud Functions → <strong>Product Engineering Agent</strong>
    <br>(Vertex AI Gemini Function Calling) → Salesforce
  </div>

  <div class="status" id="status">待機中。シナリオを選んでイベントを発火してください。</div>
</div>

<script>
const SCENARIOS = {
  'e2000': {
    btnId: 'trigger-e2000',
    valueId: 'value-e2000',
    thresholdId: 'threshold-e2000',
    base: {
      assetId: '__DEMO_ASSET_E2000_ID__',
      sensorType: 'セル温度',
      location: 'タイ・バンコク郊外 工場B棟'
    }
  },
  'a1000': {
    btnId: 'trigger-a1000',
    valueId: 'value-a1000',
    thresholdId: 'threshold-a1000',
    base: {
      assetId: '__DEMO_ASSET_A1000_ID__',
      sensorType: '振動',
      location: '中部第3拠点 風車3号機'
    }
  }
};

// ステップ進捗演出（実時間に近似）
function startProgress() {
  const prog = document.getElementById('progress');
  prog.style.display = 'block';
  document.getElementById('toolHistory').style.display = 'none';
  // すべての step を pending 状態にリセット
  prog.querySelectorAll('.progress-step').forEach(s => {
    s.classList.remove('done', 'current');
    s.querySelector('.step-icon').textContent = '○';
  });

  const schedule = [
    { step: 1, at: 0 },     // 0秒で開始
    { step: 2, at: 1500 },  // 1.5秒
    { step: 3, at: 5000 },  // 5秒
    { step: 4, at: 9000 },  // 9秒（最も時間がかかるところ）
    { step: 5, at: 25000 }, // 25秒
  ];
  schedule.forEach(({step, at}) => {
    setTimeout(() => {
      // 直前のstepをdoneに
      const prev = prog.querySelector('[data-step="' + (step - 1) + '"]');
      if (prev) {
        prev.classList.remove('current');
        prev.classList.add('done');
        prev.querySelector('.step-icon').textContent = '✓';
      }
      const cur = prog.querySelector('[data-step="' + step + '"]');
      cur.classList.add('current');
      cur.querySelector('.step-icon').textContent = '⟳';
    }, at);
  });
}

function completeProgress() {
  const prog = document.getElementById('progress');
  prog.querySelectorAll('.progress-step').forEach(s => {
    s.classList.remove('current');
    s.classList.add('done');
    s.querySelector('.step-icon').textContent = '✓';
  });
}

function showToolHistory(history) {
  const wrap = document.getElementById('toolHistory');
  const body = document.getElementById('toolHistoryBody');
  body.innerHTML = '';
  history.forEach((t, i) => {
    const row = document.createElement('div');
    row.className = 'tool-row';
    row.innerHTML =
      '<span class="tool-num">' + (i + 1) + '.</span>' +
      '<span class="tool-name">' + t.tool + '</span>' +
      '<span class="tool-args">' + (t.args || '') + '</span>' +
      '<span class="tool-result">→ ' + (t.result_summary || '') + '</span>' +
      '<span class="tool-time">' + t.elapsed_sec + 's</span>';
    body.appendChild(row);
  });
  wrap.style.display = 'block';
}

async function fireEvent(scenarioKey) {
  const cfg = SCENARIOS[scenarioKey];
  const btn = document.getElementById(cfg.btnId);
  const status = document.getElementById('status');

  // 入力値を取得
  const value = parseFloat(document.getElementById(cfg.valueId).value);
  const threshold = parseFloat(document.getElementById(cfg.thresholdId).value);

  btn.disabled = true;
  const orig = btn.textContent;
  btn.textContent = '処理中...';
  status.className = 'status';
  status.textContent = '⟳ イベントをエージェントに送信中... (' + scenarioKey.toUpperCase() + ', value=' + value + ', threshold=' + threshold + ')';

  startProgress();

  const payload = Object.assign({}, cfg.base, {
    value: value,
    threshold: threshold,
    timestamp: new Date().toISOString()
  });

  try {
    const t0 = Date.now();
    const resp = await fetch('./equipment-alert', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    const data = await resp.json();
    const elapsed = ((Date.now() - t0) / 1000).toFixed(1);

    completeProgress();

    if (resp.ok && data.alertId) {
      status.className = 'status ok';
      status.textContent =
        '✓ エージェント処理完了 (' + elapsed + '秒) / Iterations: ' + data.iterations + '\\n' +
        'Salesforce Equipment_Alert__c 作成: ' + data.alertId + '\\n' +
        '→ Salesforce で該当 Asset の「設備アラート by GCP」タブを確認';
      if (data.toolHistory) showToolHistory(data.toolHistory);
    } else {
      status.className = 'status err';
      status.textContent = '✗ エラー: ' + JSON.stringify(data, null, 2);
    }
  } catch (e) {
    status.className = 'status err';
    status.textContent = '✗ 通信エラー: ' + e.message;
  } finally {
    btn.disabled = false;
    btn.textContent = orig;
  }
}
</script>
</body>
</html>
"""
TRIGGER_HTML = _TRIGGER_HTML_TEMPLATE.replace(
    "__DEMO_ASSET_E2000_ID__", DEMO_ASSET_E2000_ID
).replace(
    "__DEMO_ASSET_A1000_ID__", DEMO_ASSET_A1000_ID
)
