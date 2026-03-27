"""
PPTX提案書をスライド画像化し、Claude Vision APIでテキスト抽出→Salesforceに書き戻すLambda関数。

処理フロー:
  1. Salesforceから呼び出し（opportunity_id + S3情報）
  2. S3からPPTXダウンロード
  3. LibreOffice で PPTX → PDF 変換
  4. poppler (pdftoppm) で PDF → スライドごとの PNG 画像変換
  5. 各スライド画像を Claude Vision API に送信してテキスト抽出
  6. 結果をSalesforce REST APIで Proposal_Context__c に書き戻し

想定タイムアウト: 300秒
"""

import base64
import glob
import json
import os
import subprocess
import shutil
import time

import anthropic
import boto3
import jwt
import requests

# リージョン設定
REGION = "ap-northeast-1"

# SSMパラメータ名
SSM_PARAM_API_KEY = "/bps-demo/anthropic-api-key"
SSM_PARAM_SF_CONSUMER_KEY = "/bps-demo/salesforce-consumer-key"
SSM_PARAM_SF_PRIVATE_KEY = "/bps-demo/salesforce-private-key"
SSM_PARAM_SF_USERNAME = "/bps-demo/salesforce-username"
SSM_PARAM_SF_INSTANCE_URL = "/bps-demo/salesforce-instance-url"

# Claude モデル
CLAUDE_MODEL = "claude-sonnet-4-20250514"

# 作業ディレクトリ（Lambdaの書き込み可能領域）
WORK_DIR = "/tmp/pptx-work"

# グローバル変数: 認証情報キャッシュ
_ssm_cache = {}


def _get_ssm_param(name: str, decrypt: bool = True) -> str:
    """SSM Parameter Storeからパラメータを取得し、キャッシュする。"""
    if name in _ssm_cache:
        return _ssm_cache[name]

    ssm = boto3.client("ssm", region_name=REGION)
    response = ssm.get_parameter(Name=name, WithDecryption=decrypt)
    value = response["Parameter"]["Value"]
    _ssm_cache[name] = value
    return value


def _get_salesforce_access_token() -> tuple[str, str]:
    """JWT Bearer FlowでSalesforceアクセストークンを取得する。(access_token, instance_url)を返す。"""
    consumer_key = _get_ssm_param(SSM_PARAM_SF_CONSUMER_KEY)
    private_key = _get_ssm_param(SSM_PARAM_SF_PRIVATE_KEY)
    username = _get_ssm_param(SSM_PARAM_SF_USERNAME)
    instance_url = _get_ssm_param(SSM_PARAM_SF_INSTANCE_URL, decrypt=False)

    # JWT生成
    payload = {
        "iss": consumer_key,
        "sub": username,
        "aud": "https://login.salesforce.com",
        "exp": int(time.time()) + 300,
    }
    assertion = jwt.encode(payload, private_key, algorithm="RS256")

    # トークン取得
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


def _update_proposal_context(
    access_token: str,
    instance_url: str,
    record_id: str,
    fields: dict,
) -> None:
    """Salesforce REST APIでProposal_Context__cレコードを更新する。"""
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
    }
    resp = requests.patch(
        f"{instance_url}/services/data/v66.0/sobjects/Proposal_Context__c/{record_id}",
        headers=headers,
        json=fields,
        timeout=30,
    )
    if resp.status_code not in (200, 204):
        raise RuntimeError(f"Salesforce更新失敗: {resp.status_code} {resp.text}")


def _create_proposal_context(
    access_token: str,
    instance_url: str,
    fields: dict,
) -> str:
    """Salesforce REST APIでProposal_Context__cレコードを作成する。作成されたレコードIDを返す。"""
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
    }
    resp = requests.post(
        f"{instance_url}/services/data/v66.0/sobjects/Proposal_Context__c",
        headers=headers,
        json=fields,
        timeout=30,
    )
    if resp.status_code != 201:
        raise RuntimeError(f"Salesforceレコード作成失敗: {resp.status_code} {resp.text}")
    return resp.json()["id"]


def _clean_work_dir():
    """作業ディレクトリを初期化する。"""
    if os.path.exists(WORK_DIR):
        shutil.rmtree(WORK_DIR)
    os.makedirs(WORK_DIR, exist_ok=True)


def _download_from_s3(bucket: str, key: str) -> str:
    """S3からPPTXファイルをダウンロードし、ローカルパスを返す。"""
    s3 = boto3.client("s3", region_name=REGION)
    local_path = os.path.join(WORK_DIR, "input.pptx")
    try:
        s3.download_file(bucket, key, local_path)
    except Exception as e:
        raise RuntimeError(f"S3からのファイル取得に失敗しました (bucket={bucket}, key={key}): {e}")
    return local_path


def _convert_pptx_to_pdf(pptx_path: str) -> str:
    """LibreOfficeを使ってPPTXをPDFに変換する。"""
    # Lambda環境ではHOMEが書き込み不可のため、/tmpをHOMEに設定
    env = os.environ.copy()
    env["HOME"] = "/tmp"
    try:
        result = subprocess.run(
            [
                "libreoffice",
                "--headless",
                "--norestore",
                "--convert-to", "pdf",
                "--outdir", WORK_DIR,
                pptx_path,
            ],
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode != 0:
            raise RuntimeError(f"LibreOffice変換エラー: {result.stderr}")
    except subprocess.TimeoutExpired:
        raise RuntimeError("LibreOfficeによるPDF変換がタイムアウトしました（120秒）")

    pdf_path = os.path.join(WORK_DIR, "input.pdf")
    if not os.path.exists(pdf_path):
        raise RuntimeError(
            f"PDF変換後のファイルが見つかりません。LibreOffice出力: {result.stdout} {result.stderr}"
        )
    return pdf_path


def _convert_pdf_to_images(pdf_path: str) -> list[str]:
    """popplerのpdftoppmを使ってPDFをスライドごとのPNG画像に変換する。"""
    output_prefix = os.path.join(WORK_DIR, "slide")
    try:
        result = subprocess.run(
            [
                "pdftoppm",
                "-png",
                "-r", "200",
                pdf_path,
                output_prefix,
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode != 0:
            raise RuntimeError(f"pdftoppm変換エラー: {result.stderr}")
    except subprocess.TimeoutExpired:
        raise RuntimeError("pdftoppmによる画像変換がタイムアウトしました（60秒）")

    image_paths = sorted(glob.glob(os.path.join(WORK_DIR, "slide-*.png")))
    if not image_paths:
        raise RuntimeError("PDF→PNG変換で画像が生成されませんでした")
    return image_paths


def _extract_slide_text(client: anthropic.Anthropic, image_path: str, slide_number: int, prompt: str) -> str:
    """1枚のスライド画像をClaude Vision APIに送信し、テキストを抽出する。"""
    with open(image_path, "rb") as f:
        image_data = base64.standard_b64encode(f.read()).decode("utf-8")

    message = client.messages.create(
        model=CLAUDE_MODEL,
        max_tokens=4096,
        messages=[
            {
                "role": "user",
                "content": [
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": "image/png",
                            "data": image_data,
                        },
                    },
                    {
                        "type": "text",
                        "text": f"スライド {slide_number} 枚目です。\n\n{prompt}",
                    },
                ],
            }
        ],
    )
    return message.content[0].text


def lambda_handler(event, context):
    """Lambda関数のエントリーポイント。"""
    try:
        # リクエストボディをパース
        if isinstance(event.get("body"), str):
            body = json.loads(event["body"])
        else:
            body = event.get("body") or event

        bucket = body["bucket"]
        key = body["key"]
        opportunity_id = body.get("opportunity_id")  # Salesforce書き戻し時に使用
        proposal_context_id = body.get("proposal_context_id")  # 既存レコード更新時
        file_url = body.get("file_url", f"s3://{bucket}/{key}")
        prompt = body.get(
            "prompt",
            "このスライドの内容を、提案書のコンテキストとして意味が通るように日本語で要約してください。"
            "図表やチャートの内容も解釈して含めてください。",
        )

        # Salesforce認証（書き戻しが必要な場合）
        sf_token = None
        sf_instance_url = None
        if opportunity_id or proposal_context_id:
            sf_token, sf_instance_url = _get_salesforce_access_token()

            # レコードが未作成の場合、「処理中」ステータスで作成
            if not proposal_context_id and opportunity_id:
                proposal_context_id = _create_proposal_context(
                    sf_token, sf_instance_url,
                    {
                        "Opportunity__c": opportunity_id,
                        "File_Name__c": key.split("/")[-1],
                        "File_URL__c": file_url,
                        "Extraction_Status__c": "処理中",
                    },
                )

        # 作業ディレクトリを初期化
        _clean_work_dir()

        # S3からPPTXをダウンロード
        pptx_path = _download_from_s3(bucket, key)

        # PPTX → PDF 変換
        pdf_path = _convert_pptx_to_pdf(pptx_path)

        # PDF → スライドごとのPNG画像変換
        image_paths = _convert_pdf_to_images(pdf_path)
        total_slides = len(image_paths)

        # Anthropicクライアントを初期化
        api_key = _get_ssm_param(SSM_PARAM_API_KEY)
        client = anthropic.Anthropic(api_key=api_key)

        # 各スライド画像からテキストを抽出
        slides = []
        for i, image_path in enumerate(image_paths, start=1):
            try:
                content = _extract_slide_text(client, image_path, i, prompt)
                slides.append({"slide_number": i, "content": content})
            except Exception as e:
                slides.append({
                    "slide_number": i,
                    "content": f"[抽出エラー] スライド{i}の処理に失敗しました: {str(e)}",
                })

        # スライドごとのテキストを連結（統合要約はSalesforce側のバッチに任せる）
        extracted_text = "\n\n".join(
            f"=== スライド {s['slide_number']} ===\n{s['content']}" for s in slides
        )

        # Salesforceに書き戻し
        if proposal_context_id and sf_token:
            _update_proposal_context(
                sf_token, sf_instance_url, proposal_context_id,
                {
                    "Extracted_Text__c": extracted_text[:131072],  # LongTextArea上限
                    "Slide_Count__c": total_slides,
                    "Extraction_Status__c": "完了",
                    "Extracted_At__c": time.strftime("%Y-%m-%dT%H:%M:%S.000+0000", time.gmtime()),
                },
            )

        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {
                    "source_file": key,
                    "total_slides": total_slides,
                    "slides": slides,
                    "proposal_context_id": proposal_context_id,
                    "extraction_status": "完了",
                },
                ensure_ascii=False,
            ),
        }

    except json.JSONDecodeError:
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {"error": "リクエストボディのJSON解析に失敗しました"},
                ensure_ascii=False,
            ),
        }
    except KeyError as e:
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {"error": f"必須パラメータが不足しています: {e}"},
                ensure_ascii=False,
            ),
        }
    except RuntimeError as e:
        # エラー時もSalesforceに書き戻し（ステータスをエラーに）
        if proposal_context_id and sf_token:
            try:
                _update_proposal_context(
                    sf_token, sf_instance_url, proposal_context_id,
                    {"Extraction_Status__c": "エラー"},
                )
            except Exception:
                pass  # エラー書き戻し自体が失敗した場合は無視
        return {
            "statusCode": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {"error": str(e)},
                ensure_ascii=False,
            ),
        }
    except Exception as e:
        if proposal_context_id and sf_token:
            try:
                _update_proposal_context(
                    sf_token, sf_instance_url, proposal_context_id,
                    {"Extraction_Status__c": "エラー"},
                )
            except Exception:
                pass
        return {
            "statusCode": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {"error": f"予期しないエラーが発生しました: {str(e)}"},
                ensure_ascii=False,
            ),
        }
    finally:
        # 作業ディレクトリをクリーンアップ
        if os.path.exists(WORK_DIR):
            shutil.rmtree(WORK_DIR, ignore_errors=True)
