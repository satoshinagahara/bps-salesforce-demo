"""
S3 Presigned URL生成 Lambda関数

API Gateway POST経由でファイル名とContent-Typeを受け取り、
S3へのPUT用Presigned URLを生成して返却する。
"""

import json
import logging

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# 定数
BUCKET_NAME = "bps-demo-proposals-938145531465"
REGION = "ap-northeast-1"
PREFIX = "proposals"
EXPIRATION_SECONDS = 300  # 5分

# S3クライアント（署名バージョンv4を明示指定）
s3_client = boto3.client(
    "s3",
    region_name=REGION,
    config=Config(signature_version="s3v4"),
)


def lambda_handler(event, context):
    """
    Presigned URL生成ハンドラ。

    API Gateway経由（event["body"]が文字列）と
    Lambda直接呼び出し（eventが直接dict）の両方に対応。
    """
    try:
        # リクエストボディの解析
        body = _parse_body(event)

        # 必須パラメータの検証
        file_name = body.get("file_name")
        content_type = body.get("content_type")

        if not file_name:
            return _error_response(400, "file_name は必須です")
        if not content_type:
            return _error_response(400, "content_type は必須です")

        # S3キーの組み立て
        s3_key = f"{PREFIX}/{file_name}"

        # Presigned URL生成
        presigned_url = s3_client.generate_presigned_url(
            ClientMethod="put_object",
            Params={
                "Bucket": BUCKET_NAME,
                "Key": s3_key,
                "ContentType": content_type,
            },
            ExpiresIn=EXPIRATION_SECONDS,
        )

        logger.info("Presigned URL生成成功: bucket=%s, key=%s", BUCKET_NAME, s3_key)

        return _success_response(
            {
                "presigned_url": presigned_url,
                "s3_key": s3_key,
                "bucket": BUCKET_NAME,
            }
        )

    except json.JSONDecodeError:
        logger.warning("リクエストボディのJSONパースに失敗")
        return _error_response(400, "リクエストボディが不正なJSON形式です")
    except ClientError as e:
        logger.error("S3 Presigned URL生成エラー: %s", str(e))
        return _error_response(500, f"Presigned URL生成に失敗しました: {str(e)}")
    except Exception as e:
        logger.error("予期しないエラー: %s", str(e))
        return _error_response(500, "内部エラーが発生しました")


def _parse_body(event):
    """
    イベントからリクエストボディを解析する。

    API Gateway経由: event["body"]が JSON文字列 → パースして返却
    Lambda直接呼び出し: event自体がdict → そのまま返却
    """
    body = event.get("body")
    if body is None:
        # Lambda直接呼び出し（eventそのものがパラメータ）
        return event
    if isinstance(body, str):
        # API Gateway経由（bodyがJSON文字列）
        return json.loads(body)
    # bodyがすでにdictの場合（API Gatewayプロキシ統合の一部ケース）
    return body


def _success_response(data):
    """成功レスポンスを組み立てる（API Gateway互換形式）"""
    return {
        "statusCode": 200,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(data),
    }


def _error_response(status_code, message):
    """エラーレスポンスを組み立てる（API Gateway互換形式）"""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps({"error": message}),
    }
