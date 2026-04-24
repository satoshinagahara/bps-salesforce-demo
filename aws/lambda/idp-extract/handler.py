"""
IDP本体: サプライヤー見積書をClaude Sonnet 4.6で抽出し、
RFQ_Quote__cのAI影フィールドに書き戻すLambda関数。

処理フロー:
  1. S3から見積書(PDF/PNG/JPG)ダウンロード
  2. Claude Sonnet 4.6 (tool_use) に直接送信 → 構造化JSON抽出
     - PDFはDocumentブロック、画像はImageブロックで送る
  3. JWT Bearer FlowでSalesforceアクセストークン取得
  4. REST APIで RFQ_Quote__c にPATCH(AI_* 影フィールド + 信頼度 + ステータス更新)

想定タイムアウト: 300秒
"""

import base64
import json
import logging
import os
import time
from typing import Any

import anthropic
import boto3
import jwt
import requests

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = "ap-northeast-1"

SSM_PARAM_API_KEY = "/bps-demo/anthropic-api-key"
SSM_PARAM_SF_CONSUMER_KEY = "/bps-demo/salesforce-consumer-key"
SSM_PARAM_SF_PRIVATE_KEY = "/bps-demo/salesforce-private-key"
SSM_PARAM_SF_USERNAME = "/bps-demo/salesforce-username"
SSM_PARAM_SF_INSTANCE_URL = "/bps-demo/salesforce-instance-url"

CLAUDE_MODEL = "claude-sonnet-4-6"

WORK_DIR = "/tmp/idp-work"

_ssm_cache: dict[str, str] = {}


# ============================================================
# SSM / Salesforce 認証ユーティリティ
# ============================================================

def _get_ssm_param(name: str, decrypt: bool = True) -> str:
    if name in _ssm_cache:
        return _ssm_cache[name]
    ssm = boto3.client("ssm", region_name=REGION)
    response = ssm.get_parameter(Name=name, WithDecryption=decrypt)
    value = response["Parameter"]["Value"]
    _ssm_cache[name] = value
    return value


def _get_salesforce_access_token() -> tuple[str, str]:
    consumer_key = _get_ssm_param(SSM_PARAM_SF_CONSUMER_KEY)
    private_key = _get_ssm_param(SSM_PARAM_SF_PRIVATE_KEY)
    username = _get_ssm_param(SSM_PARAM_SF_USERNAME)
    instance_url = _get_ssm_param(SSM_PARAM_SF_INSTANCE_URL, decrypt=False)

    payload = {
        "iss": consumer_key,
        "sub": username,
        "aud": "https://login.salesforce.com",
        "exp": int(time.time()) + 300,
    }
    assertion = jwt.encode(payload, private_key, algorithm="RS256")

    resp = requests.post(
        "https://login.salesforce.com/services/oauth2/token",
        data={
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
        },
        timeout=30,
    )
    if resp.status_code != 200:
        raise RuntimeError(f"Salesforce認証失敗: {resp.status_code} {resp.text}")

    data = resp.json()
    return data["access_token"], data.get("instance_url", instance_url)


def _patch_rfq_quote(
    access_token: str,
    instance_url: str,
    record_id: str,
    fields: dict,
) -> None:
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
    }
    resp = requests.patch(
        f"{instance_url}/services/data/v66.0/sobjects/RFQ_Quote__c/{record_id}",
        headers=headers,
        json=fields,
        timeout=30,
    )
    if resp.status_code not in (200, 204):
        raise RuntimeError(f"Salesforce更新失敗: {resp.status_code} {resp.text}")


# ============================================================
# S3 / Claude 呼び出し
# ============================================================

def _download_from_s3(bucket: str, key: str) -> tuple[bytes, str]:
    """S3からドキュメントをバイト列で取得。 (content_bytes, content_type) を返す。"""
    s3 = boto3.client("s3", region_name=REGION)
    resp = s3.get_object(Bucket=bucket, Key=key)
    content_type = resp.get("ContentType", "application/octet-stream")
    content = resp["Body"].read()
    return content, content_type


def _build_tool_schema() -> list[dict]:
    """Claude tool_use用のJSON Schema。各項目につき value + confidence を必須とする。"""
    def field_object(value_type: list[str]) -> dict:
        return {
            "type": "object",
            "properties": {
                "value": {"type": value_type},
                "confidence": {
                    "type": "number",
                    "minimum": 0,
                    "maximum": 1,
                    "description": "0-1の信頼度スコア",
                },
            },
            "required": ["value", "confidence"],
        }

    return [
        {
            "name": "extract_quote_fields",
            "description": "サプライヤー見積書から定義済みフィールドを抽出する",
            "input_schema": {
                "type": "object",
                "properties": {
                    "supplier_name": field_object(["string", "null"]),
                    "unit_price": field_object(["number", "null"]),
                    "lead_time_days": field_object(["number", "null"]),
                    "moq": field_object(["number", "null"]),
                    "manufacturing_site": field_object(["string", "null"]),
                    "valid_until": field_object(["string", "null"]),
                    "response_date": field_object(["string", "null"]),
                    "notes": {
                        "type": "string",
                        "description": "抽出中の特記事項(任意)",
                    },
                },
                "required": [
                    "supplier_name",
                    "unit_price",
                    "lead_time_days",
                    "moq",
                    "manufacturing_site",
                    "valid_until",
                    "response_date",
                ],
            },
        }
    ]


def _build_system_prompt() -> str:
    return (
        "あなたは製造業向けのインテリジェントドキュメント処理(IDP)エンジンです。"
        "提供されたサプライヤー見積書から、extract_quote_fields ツールを使って"
        "以下のスキーマで項目値を抽出してください。\n"
        "\n"
        "# 抽出ルール\n"
        "- supplier_name: 見積書発行元の法人名。法人格(株式会社等)を含む正式名称\n"
        "- unit_price: 税抜き単価。通貨記号・カンマ除いた数値のみ。JPY想定\n"
        "- lead_time_days: 発注から納品までの日数。「○週間」表記なら日数換算(1週=7日)\n"
        "- moq: 最小発注数量(数値のみ)\n"
        "- manufacturing_site: 製造拠点名(工場名、所在地等)\n"
        "- valid_until: 見積有効期限。ISO 8601形式(YYYY-MM-DD)。和暦は西暦変換\n"
        "- response_date: 見積書発行日。ISO 8601形式(YYYY-MM-DD)\n"
        "\n"
        "- 読み取れない項目は value=null, confidence=0.0\n"
        "- 各項目に 0-1 の信頼度スコアを付与(自信度)\n"
        "- 複数ページの場合は全ページを参照して矛盾しない値を採用\n"
    )


def _call_claude(pdf_or_image_bytes: bytes, content_type: str) -> dict:
    """Claude Sonnet 4.6 に見積書を送信し、構造化抽出結果を取得。"""
    api_key = _get_ssm_param(SSM_PARAM_API_KEY)
    client = anthropic.Anthropic(api_key=api_key)

    b64_data = base64.standard_b64encode(pdf_or_image_bytes).decode("utf-8")

    # PDFはdocumentブロック、画像はimageブロック
    if content_type == "application/pdf":
        doc_block = {
            "type": "document",
            "source": {
                "type": "base64",
                "media_type": "application/pdf",
                "data": b64_data,
            },
        }
    elif content_type in ("image/png", "image/jpeg", "image/jpg"):
        # image/jpg は正式には image/jpeg
        media_type = "image/jpeg" if content_type == "image/jpg" else content_type
        doc_block = {
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": media_type,
                "data": b64_data,
            },
        }
    else:
        raise RuntimeError(f"サポートされていないContent-Type: {content_type}")

    message = client.messages.create(
        model=CLAUDE_MODEL,
        max_tokens=4096,
        system=_build_system_prompt(),
        tools=_build_tool_schema(),
        tool_choice={"type": "tool", "name": "extract_quote_fields"},
        messages=[
            {
                "role": "user",
                "content": [
                    doc_block,
                    {
                        "type": "text",
                        "text": "このサプライヤー見積書から定義済みの項目を抽出してください。",
                    },
                ],
            }
        ],
    )

    for block in message.content:
        if block.type == "tool_use" and block.name == "extract_quote_fields":
            return block.input

    raise RuntimeError(f"Claudeから tool_use 応答を得られませんでした: {message.content}")


# ============================================================
# 抽出結果 → Salesforce 書き戻し項目マッピング
# ============================================================

def _extraction_to_sf_fields(extraction: dict) -> dict:
    """Claude抽出結果(JSON) → RFQ_Quote__c PATCH用 fields dict への変換。"""
    def val(key: str) -> Any:
        return (extraction.get(key) or {}).get("value")

    def conf(key: str) -> int:
        """信頼度 0-1 を 0-100 の整数(Percent型用)に変換。"""
        c = (extraction.get(key) or {}).get("confidence")
        if c is None:
            return 0
        return int(round(float(c) * 100))

    fields: dict[str, Any] = {
        "AI_Supplier_Text__c": val("supplier_name"),
        "AI_Supplier_Confidence__c": conf("supplier_name"),
        "AI_Unit_Price__c": val("unit_price"),
        "AI_Unit_Price_Confidence__c": conf("unit_price"),
        "AI_Lead_Time_Days__c": val("lead_time_days"),
        "AI_Lead_Time_Days_Confidence__c": conf("lead_time_days"),
        "AI_MOQ__c": val("moq"),
        "AI_MOQ_Confidence__c": conf("moq"),
        "AI_Manufacturing_Site__c": val("manufacturing_site"),
        "AI_Manufacturing_Site_Confidence__c": conf("manufacturing_site"),
        "AI_Valid_Until__c": val("valid_until"),
        "AI_Valid_Until_Confidence__c": conf("valid_until"),
        "AI_Response_Date__c": val("response_date"),
        "AI_Response_Date_Confidence__c": conf("response_date"),
        "IDP_Extracted_At__c": time.strftime(
            "%Y-%m-%dT%H:%M:%S.000+0000", time.gmtime()
        ),
        "IDP_Review_Status__c": "AI判定待ち",
        "IDP_Error_Message__c": None,
    }
    return fields


# ============================================================
# Lambda エントリーポイント
# ============================================================

def lambda_handler(event, context):
    rfq_quote_id = None
    sf_token = None
    sf_instance_url = None

    try:
        if isinstance(event.get("body"), str):
            body = json.loads(event["body"])
        else:
            body = event.get("body") or event

        bucket = body["bucket"]
        key = body["key"]
        rfq_quote_id = body["rfq_quote_id"]

        logger.info("IDP抽出開始: rfq_quote_id=%s, s3=%s/%s", rfq_quote_id, bucket, key)

        # Salesforce認証
        sf_token, sf_instance_url = _get_salesforce_access_token()

        # S3からドキュメント取得
        content_bytes, content_type = _download_from_s3(bucket, key)
        logger.info("S3取得完了: content_type=%s, size=%d bytes", content_type, len(content_bytes))

        # S3のContent-Typeが汎用(application/octet-stream)の場合はファイル名から推測
        if content_type == "application/octet-stream":
            lower = key.lower()
            if lower.endswith(".pdf"):
                content_type = "application/pdf"
            elif lower.endswith(".png"):
                content_type = "image/png"
            elif lower.endswith(".jpg") or lower.endswith(".jpeg"):
                content_type = "image/jpeg"

        # Claude抽出
        extraction = _call_claude(content_bytes, content_type)
        logger.info("Claude抽出完了: %s", json.dumps(extraction, ensure_ascii=False)[:500])

        # Salesforceに書き戻し
        fields = _extraction_to_sf_fields(extraction)
        _patch_rfq_quote(sf_token, sf_instance_url, rfq_quote_id, fields)

        logger.info("RFQ_Quote更新完了: %s", rfq_quote_id)

        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {
                    "rfq_quote_id": rfq_quote_id,
                    "status": "ダブルチェック待ち",
                    "extraction": extraction,
                },
                ensure_ascii=False,
            ),
        }

    except KeyError as e:
        logger.error("必須パラメータ不足: %s", str(e))
        _try_mark_error(sf_token, sf_instance_url, rfq_quote_id, f"必須パラメータ不足: {e}")
        return _error_response(400, f"必須パラメータが不足しています: {e}")
    except RuntimeError as e:
        logger.error("RuntimeError: %s", str(e))
        _try_mark_error(sf_token, sf_instance_url, rfq_quote_id, str(e)[:255])
        return _error_response(500, str(e))
    except Exception as e:
        logger.exception("予期しないエラー")
        _try_mark_error(
            sf_token, sf_instance_url, rfq_quote_id, f"予期しないエラー: {str(e)[:200]}"
        )
        return _error_response(500, f"予期しないエラー: {str(e)}")


def _try_mark_error(sf_token, sf_instance_url, rfq_quote_id, message):
    """エラー時にSalesforce側のIDP_Review_Status__cを"エラー"に更新(ベストエフォート)。"""
    if not (sf_token and sf_instance_url and rfq_quote_id):
        # SF認証前のエラーはSFに書き込めないのでスキップ
        try:
            if rfq_quote_id and not sf_token:
                sf_token, sf_instance_url = _get_salesforce_access_token()
        except Exception:
            return
    try:
        # ステータスは変更せず、エラーメッセージのみ書き戻す(LWC側でバナー表示)
        _patch_rfq_quote(
            sf_token,
            sf_instance_url,
            rfq_quote_id,
            {
                "IDP_Error_Message__c": message[:255] if message else "不明なエラー",
            },
        )
    except Exception as exc:
        logger.error("エラー書き戻し失敗: %s", str(exc))


def _error_response(status_code, message):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": message}, ensure_ascii=False),
    }
