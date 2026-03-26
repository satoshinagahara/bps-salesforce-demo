"""
PPTX提案書をスライド画像化し、Claude Vision APIでテキスト抽出するLambda関数。

処理フロー:
  1. API Gateway POST → S3からPPTXダウンロード
  2. LibreOffice で PPTX → PDF 変換
  3. poppler (pdftoppm) で PDF → スライドごとの PNG 画像変換
  4. 各スライド画像を Claude Vision API に送信してテキスト抽出
  5. 全スライドの統合要約を生成して返却

想定タイムアウト: 300秒
"""

import base64
import glob
import json
import os
import subprocess
import shutil

import anthropic
import boto3

# リージョン設定
REGION = "ap-northeast-1"

# SSMパラメータ名
SSM_PARAM_API_KEY = "/bps-demo/anthropic-api-key"

# Claude モデル
CLAUDE_MODEL = "claude-sonnet-4-20250514"

# 作業ディレクトリ（Lambdaの書き込み可能領域）
WORK_DIR = "/tmp/pptx-work"

# グローバル変数: Anthropic APIキーをキャッシュ
_anthropic_api_key = None


def _get_anthropic_api_key():
    """SSM Parameter StoreからAnthropicAPIキーを取得し、グローバル変数にキャッシュする。"""
    global _anthropic_api_key
    if _anthropic_api_key is not None:
        return _anthropic_api_key

    ssm = boto3.client("ssm", region_name=REGION)
    response = ssm.get_parameter(Name=SSM_PARAM_API_KEY, WithDecryption=True)
    _anthropic_api_key = response["Parameter"]["Value"]
    return _anthropic_api_key


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
            timeout=120,  # LibreOffice変換のタイムアウト
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
                "-r", "200",  # 解像度200dpi（品質と処理速度のバランス）
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

    # 生成されたPNG画像をスライド番号順にソートして返す
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


def _generate_combined_summary(client: anthropic.Anthropic, slides: list[dict], source_file: str) -> str:
    """全スライドの抽出テキストを統合して要約を生成する。"""
    slides_text = "\n\n".join(
        f"=== スライド {s['slide_number']} ===\n{s['content']}" for s in slides
    )

    message = client.messages.create(
        model=CLAUDE_MODEL,
        max_tokens=4096,
        messages=[
            {
                "role": "user",
                "content": (
                    f"以下は提案書「{source_file}」の各スライドから抽出したテキストです。\n\n"
                    f"{slides_text}\n\n"
                    "上記の全スライドの内容を統合し、提案書全体の要約を日本語で作成してください。"
                    "提案の目的、主要なポイント、提案内容の構成がわかるように整理してください。"
                ),
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
        prompt = body.get(
            "prompt",
            "このスライドの内容を、提案書のコンテキストとして意味が通るように日本語で要約してください。"
            "図表やチャートの内容も解釈して含めてください。",
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
        api_key = _get_anthropic_api_key()
        client = anthropic.Anthropic(api_key=api_key)

        # 各スライド画像からテキストを抽出
        slides = []
        for i, image_path in enumerate(image_paths, start=1):
            try:
                content = _extract_slide_text(client, image_path, i, prompt)
                slides.append({"slide_number": i, "content": content})
            except Exception as e:
                # 個別スライドのエラーは記録して続行
                slides.append({
                    "slide_number": i,
                    "content": f"[抽出エラー] スライド{i}の処理に失敗しました: {str(e)}",
                })

        # 全スライドの統合要約を生成
        try:
            combined_summary = _generate_combined_summary(client, slides, key)
        except Exception as e:
            combined_summary = f"[要約生成エラー] 統合要約の生成に失敗しました: {str(e)}"

        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {
                    "source_file": key,
                    "total_slides": total_slides,
                    "slides": slides,
                    "combined_summary": combined_summary,
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
        return {
            "statusCode": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {"error": str(e)},
                ensure_ascii=False,
            ),
        }
    except Exception as e:
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
