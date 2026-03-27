"""
テキスト抽出処理のディスパッチャLambda関数。

API Gateway経由で同期的に呼ばれ、pptx-extractorを非同期で起動する。
即座にレスポンスを返すことでAPI Gatewayのタイムアウト（29秒）を回避。
"""

import json
import logging

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = "ap-northeast-1"
EXTRACTOR_FUNCTION = "bps-demo-pptx-extractor"

lambda_client = boto3.client("lambda", region_name=REGION)


def lambda_handler(event, context):
    """pptx-extractorを非同期呼び出しして即座にレスポンスを返す。"""
    try:
        body = event.get("body")
        if isinstance(body, str):
            body = json.loads(body)
        elif body is None:
            body = event

        # pptx-extractorを非同期呼び出し（InvocationType=Event）
        lambda_client.invoke(
            FunctionName=EXTRACTOR_FUNCTION,
            InvocationType="Event",
            Payload=json.dumps(body),
        )

        logger.info("pptx-extractor を非同期起動: %s", json.dumps(body, ensure_ascii=False))

        return {
            "statusCode": 202,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"message": "抽出処理を開始しました"}, ensure_ascii=False),
        }
    except json.JSONDecodeError:
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "不正なJSON"}, ensure_ascii=False),
        }
    except Exception as e:
        logger.error("ディスパッチエラー: %s", str(e))
        return {
            "statusCode": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": str(e)}, ensure_ascii=False),
        }
