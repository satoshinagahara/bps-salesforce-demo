"""
IDP用 S3 Presigned URL生成 Lambda関数

サプライヤー見積書(PDF/PNG/JPG)のS3アップロード用Presigned URLを発行する。
既存のpresign-urlと同じ構造だが、PREFIXを `idp-supplier-quote/` に分離。
"""

import json
import logging
import uuid

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BUCKET_NAME = "bps-demo-proposals-938145531465"
REGION = "ap-northeast-1"
PREFIX = "idp-supplier-quote"
EXPIRATION_SECONDS = 300

ALLOWED_CONTENT_TYPES = {
    "application/pdf",
    "image/png",
    "image/jpeg",
    "image/jpg",
}

s3_client = boto3.client(
    "s3",
    region_name=REGION,
    config=Config(signature_version="s3v4"),
)


def lambda_handler(event, context):
    try:
        body = _parse_body(event)
        mode = body.get("mode", "upload")  # "upload" (default) or "view"

        if mode == "view":
            return _handle_view(body)

        # === Upload mode (default) ===
        file_name = body.get("file_name")
        content_type = body.get("content_type")

        if not file_name:
            return _error_response(400, "file_name は必須です")
        if not content_type:
            return _error_response(400, "content_type は必須です")
        if content_type not in ALLOWED_CONTENT_TYPES:
            return _error_response(
                400,
                f"許可されていないContent-Typeです: {content_type}. "
                f"許可: {', '.join(sorted(ALLOWED_CONTENT_TYPES))}",
            )

        # S3キー: `idp-supplier-quote/{uuid}-{filename}` でユニーク化
        unique_id = uuid.uuid4().hex[:12]
        s3_key = f"{PREFIX}/{unique_id}-{file_name}"

        presigned_url = s3_client.generate_presigned_url(
            ClientMethod="put_object",
            Params={
                "Bucket": BUCKET_NAME,
                "Key": s3_key,
                "ContentType": content_type,
            },
            ExpiresIn=EXPIRATION_SECONDS,
        )

        logger.info("IDP Presigned URL生成成功(upload): bucket=%s, key=%s", BUCKET_NAME, s3_key)

        return _success_response(
            {
                "presigned_url": presigned_url,
                "s3_key": s3_key,
                "bucket": BUCKET_NAME,
            }
        )

    except json.JSONDecodeError:
        return _error_response(400, "リクエストボディが不正なJSON形式です")
    except ClientError as e:
        logger.error("S3 Presigned URL生成エラー: %s", str(e))
        return _error_response(500, f"Presigned URL生成に失敗しました: {str(e)}")
    except Exception as e:
        logger.error("予期しないエラー: %s", str(e))
        return _error_response(500, "内部エラーが発生しました")


def _handle_view(body):
    """GETメソッド用 Presigned URL生成(ドキュメント閲覧用、有効期限15分)"""
    s3_key = body.get("s3_key")
    if not s3_key:
        return _error_response(400, "s3_key は必須です")

    try:
        view_url = s3_client.generate_presigned_url(
            ClientMethod="get_object",
            Params={
                "Bucket": BUCKET_NAME,
                "Key": s3_key,
            },
            ExpiresIn=900,  # 15分
        )
    except ClientError as e:
        logger.error("View URL生成エラー: %s", str(e))
        return _error_response(500, f"View URL生成失敗: {str(e)}")

    logger.info("IDP Presigned URL生成成功(view): bucket=%s, key=%s", BUCKET_NAME, s3_key)
    return _success_response({"view_url": view_url, "expires_in_sec": 900})


def _parse_body(event):
    body = event.get("body")
    if body is None:
        return event
    if isinstance(body, str):
        return json.loads(body)
    return body


def _success_response(data):
    return {
        "statusCode": 200,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(data),
    }


def _error_response(status_code, message):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps({"error": message}),
    }
