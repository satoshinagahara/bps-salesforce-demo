"""
Product Engineering Agent (Vertex AI Gemini Function Calling)

製品エンジニアリングに関わる問い合わせ・イベント解釈を担うAIエージェント。
ツール群を定義し、Geminiが必要なツールを自律的に呼び出して結論を導く。

現在対応するユースケース:
  - シナリオ2: IoT 設備異常イベントの業務的解釈 + Salesforce書き戻し

将来対応予定:
  - シナリオ1: 製品施策に対する設計改善提案（現在は固定パイプライン実装）
  - 製品仕様問い合わせ
  - 故障原因調査
"""
from __future__ import annotations

import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone
from typing import Any

import requests as http_requests
import vertexai
from google.cloud import storage
from vertexai.generative_models import (
    Content,
    FunctionDeclaration,
    GenerativeModel,
    Part,
    Tool,
)

log = logging.getLogger("product-engineering-agent")

GCP_PROJECT = os.environ.get("GCP_PROJECT", "ageless-lamp-251200")
VERTEX_LOCATION = os.environ.get("VERTEX_LOCATION", "us-central1")
VERTEX_MODEL = os.environ.get("VERTEX_MODEL", "gemini-2.5-flash")
GCS_BUCKET = os.environ.get("GCS_BUCKET", "bps-design-assets")

# --- 製品名 → GCS 資産マッピング（既存と共通） ---
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


# ============================================================
# ツール実装（エージェントから呼び出される実関数）
# ============================================================

def tool_get_asset_info(asset_id: str, sf_access_token: str, sf_instance_url: str) -> dict:
    """Salesforceから Asset レコードの情報を取得する。"""
    log.info("[tool] get_asset_info: %s", asset_id)
    soql = (
        "SELECT Id, Name, SerialNumber, InstallDate, Status, Price, "
        "Account.Name, Product2.Name, Description "
        "FROM Asset WHERE Id = '" + asset_id + "'"
    )
    url = f"{sf_instance_url}/services/data/v62.0/query?q={http_requests.utils.quote(soql)}"
    resp = http_requests.get(
        url,
        headers={"Authorization": f"Bearer {sf_access_token}"},
        timeout=30,
    )
    resp.raise_for_status()
    records = resp.json().get("records", [])
    if not records:
        return {"error": f"Asset {asset_id} not found"}
    a = records[0]
    return {
        "assetId": a["Id"],
        "assetName": a.get("Name"),
        "serialNumber": a.get("SerialNumber"),
        "installDate": a.get("InstallDate"),
        "status": a.get("Status"),
        "price": a.get("Price"),
        "accountName": (a.get("Account") or {}).get("Name"),
        "productName": (a.get("Product2") or {}).get("Name"),
        "description": a.get("Description"),
    }


def tool_get_product_spec(product_name: str, storage_client: storage.Client) -> dict:
    """製品名からGCS上の仕様書PDFを取得する。"""
    log.info("[tool] get_product_spec: %s", product_name)
    spec_path = _resolve_spec_path(product_name)
    if not spec_path:
        return {"error": f"No spec found for product '{product_name}'"}
    blob = storage_client.bucket(GCS_BUCKET).blob(spec_path)
    pdf_bytes = blob.download_as_bytes()
    return {
        "productName": product_name,
        "specPath": spec_path,
        "pdfBytes": pdf_bytes,  # 後段でPart化する
        "sizeBytes": len(pdf_bytes),
    }


def tool_get_product_diagram(product_name: str, storage_client: storage.Client) -> dict:
    """製品名からGCS上の図面PNGを取得する。"""
    log.info("[tool] get_product_diagram: %s", product_name)
    diagram_path = _resolve_diagram_path(product_name)
    if not diagram_path:
        return {"error": f"No diagram found for product '{product_name}'"}
    blob = storage_client.bucket(GCS_BUCKET).blob(diagram_path)
    png_bytes = blob.download_as_bytes()
    return {
        "productName": product_name,
        "diagramPath": diagram_path,
        "pngBytes": png_bytes,
        "sizeBytes": len(png_bytes),
    }


def tool_calculate_severity(value: float, threshold: float, sensor_type: str) -> dict:
    """検知値・閾値・センサー種別から重要度を判定する。簡易ロジック。"""
    log.info("[tool] calculate_severity: %s value=%s threshold=%s", sensor_type, value, threshold)
    if value <= threshold:
        return {"severity": "低", "reason": "閾値内"}
    excess_ratio = (value - threshold) / threshold
    if excess_ratio >= 0.10:
        sev = "高"
        reason = f"閾値を{excess_ratio*100:.1f}%超過。即時対応推奨"
    elif excess_ratio >= 0.03:
        sev = "中"
        reason = f"閾値を{excess_ratio*100:.1f}%超過。早期対応推奨"
    else:
        sev = "低"
        reason = f"閾値を僅かに超過（{excess_ratio*100:.1f}%）"
    return {"severity": sev, "reason": reason}


def tool_estimate_opportunity(asset_price: float, severity: str, sensor_type: str) -> dict:
    """設備の納入価格と重要度から、想定商談機会金額を試算する。

    ロジック: 納入価格 × 重要度係数
      - 高: 1.5（即時の設備更新 + 3年保守契約相当）
      - 中: 0.6（部分修理 + 延長保守契約）
      - 低: 0.15（点検サービスのみ）
    """
    log.info("[tool] estimate_opportunity: price=%s severity=%s", asset_price, severity)
    if not asset_price or asset_price <= 0:
        return {"error": "asset_price required (>0)"}
    multiplier = {"高": 1.5, "中": 0.6, "低": 0.15}.get(severity, 0.6)
    multiplier_label = {
        "高": "設備更新＋3年保守契約相当",
        "中": "部分修理＋延長保守契約",
        "低": "点検サービス相当",
    }.get(severity, "")
    estimated = int(asset_price * multiplier)
    return {
        "estimatedOpportunity": estimated,
        "currency": "JPY",
        "rationale": (
            f"納入価格 ¥{int(asset_price):,} × {multiplier}（{multiplier_label}）"
            f" = ¥{estimated:,}"
        ),
    }


def tool_write_equipment_alert(
    asset_id: str,
    sensor_type: str,
    detected_value: float,
    threshold: float,
    severity: str,
    anomaly_description: str,
    recommended_action: str,
    estimated_opportunity: int,
    opportunity_rationale: str,
    sf_access_token: str,
    sf_instance_url: str,
    request_id: str,
) -> dict:
    """Salesforceに Equipment_Alert__c レコードを作成する。"""
    log.info("[tool] write_equipment_alert: asset=%s severity=%s", asset_id, severity)
    record = {
        "Asset__c": asset_id,
        "Sensor_Type__c": sensor_type,
        "Detected_Value__c": detected_value,
        "Threshold__c": threshold,
        "Severity__c": severity,
        "Detected_At__c": datetime.now(timezone.utc).isoformat(),
        "Anomaly_Description__c": anomaly_description,
        "Recommended_Action__c": recommended_action,
        "Estimated_Opportunity__c": estimated_opportunity,
        "Opportunity_Rationale__c": opportunity_rationale,
        "ProcessedBy__c": f"Vertex AI {VERTEX_MODEL} (Agent)",
        "GcpRequestId__c": request_id,
        "Status__c": "新規",
    }
    url = f"{sf_instance_url}/services/data/v62.0/sobjects/Equipment_Alert__c"
    resp = http_requests.post(
        url,
        headers={"Authorization": f"Bearer {sf_access_token}", "Content-Type": "application/json"},
        json=record,
        timeout=30,
    )
    if resp.status_code == 201:
        record_id = resp.json().get("id")
        return {"alertId": record_id, "status": "created"}
    return {"error": resp.text, "statusCode": resp.status_code}


# ============================================================
# ヘルパー
# ============================================================

def _resolve_spec_path(product_name: str) -> str | None:
    for assets in PRODUCT_ASSETS.values():
        for kw in assets["keywords"]:
            if kw in product_name:
                return assets["spec"]
    return None


def _resolve_diagram_path(product_name: str) -> str | None:
    for assets in PRODUCT_ASSETS.values():
        for kw in assets["keywords"]:
            if kw in product_name:
                return assets["diagram"]
    return None


# ============================================================
# Function Calling のスキーマ定義
# ============================================================

FUNCTION_DECLARATIONS = [
    FunctionDeclaration(
        name="get_asset_info",
        description="SalesforceのAssetレコードIDから設備情報（製品名・取引先・設置場所等）を取得する",
        parameters={
            "type": "object",
            "properties": {
                "asset_id": {"type": "string", "description": "Asset レコードID"},
            },
            "required": ["asset_id"],
        },
    ),
    FunctionDeclaration(
        name="get_product_spec",
        description="製品名から該当する製品仕様書PDFを取得する。仕様書には設計仕様・既知課題・制御アルゴリズム等が記載されている",
        parameters={
            "type": "object",
            "properties": {
                "product_name": {"type": "string", "description": "製品名（例: EnerCharge Pro 蓄電システム）"},
            },
            "required": ["product_name"],
        },
    ),
    FunctionDeclaration(
        name="get_product_diagram",
        description="製品名から該当する設計図面（PNG）を取得する",
        parameters={
            "type": "object",
            "properties": {
                "product_name": {"type": "string"},
            },
            "required": ["product_name"],
        },
    ),
    FunctionDeclaration(
        name="calculate_severity",
        description="センサー検知値と閾値から異常の重要度（高/中/低）を判定する",
        parameters={
            "type": "object",
            "properties": {
                "value": {"type": "number", "description": "検知値"},
                "threshold": {"type": "number", "description": "閾値"},
                "sensor_type": {"type": "string", "description": "センサー種別（例: セル温度）"},
            },
            "required": ["value", "threshold", "sensor_type"],
        },
    ),
    FunctionDeclaration(
        name="estimate_opportunity",
        description=(
            "設備の納入価格(asset_price)と重要度から想定商談機会金額（円）を試算する。"
            "asset_price は get_asset_info で取得した price フィールド値を使うこと。"
        ),
        parameters={
            "type": "object",
            "properties": {
                "asset_price": {"type": "number", "description": "設備の納入価格（円）"},
                "severity": {"type": "string", "enum": ["高", "中", "低"]},
                "sensor_type": {"type": "string"},
            },
            "required": ["asset_price", "severity", "sensor_type"],
        },
    ),
    FunctionDeclaration(
        name="write_equipment_alert",
        description=(
            "全ての分析が完了したら最後にこの関数を呼び、Salesforceの Equipment_Alert__c に診断結果を書き戻す。"
            "anomaly_description は仕様書のセクション番号を引用しながら3〜5文で記述。"
            "recommended_action は箇条書き（行頭'・'）で2〜4項目。"
            "opportunity_rationale には estimate_opportunity ツールが返した rationale 文字列をそのまま渡す。"
        ),
        parameters={
            "type": "object",
            "properties": {
                "asset_id": {"type": "string"},
                "sensor_type": {"type": "string"},
                "detected_value": {"type": "number"},
                "threshold": {"type": "number"},
                "severity": {"type": "string", "enum": ["高", "中", "低"]},
                "anomaly_description": {"type": "string"},
                "recommended_action": {"type": "string"},
                "estimated_opportunity": {"type": "integer"},
                "opportunity_rationale": {"type": "string", "description": "商談機会金額の算出根拠（estimate_opportunity の rationale をそのまま）"},
            },
            "required": [
                "asset_id", "sensor_type", "detected_value", "threshold",
                "severity", "anomaly_description", "recommended_action",
                "estimated_opportunity", "opportunity_rationale",
            ],
        },
    ),
]


# ============================================================
# エージェントランタイム
# ============================================================

SYSTEM_INSTRUCTION = """\
あなたは BPS Corporation の Product Engineering Agent です。
製品の設計仕様・図面に精通し、設備の異常イベントを業務的に解釈して
Salesforceの担当営業に届けるのが役割です。

## あなたが扱うイベント
IoTセンサーから設備の異常検知イベントが届きます。例：
{"assetId": "...", "sensorType": "セル温度", "value": 47.5, "threshold": 45.0, "location": "..."}

## あなたが行うべき手順
1. get_asset_info でAsset情報（製品名・取引先・設置場所）を取得
2. get_product_spec で対象製品の仕様書PDFを取得
3. get_product_diagram で対象製品の図面PNGを取得（参考情報）
4. calculate_severity で重要度を判定
5. estimate_opportunity で想定商談機会金額を試算
6. 仕様書PDFと図面を読み解き、検知値が業務的に何を意味するか診断する
   - 仕様書のセクション番号（例: P.3 §3.2）を必ず引用する
   - 「既知課題」セクションがあれば該当性を検証する
7. write_equipment_alert で Salesforce に診断結果を書き戻す
8. 完了応答を返す

## 診断テキストのスタイル
- 「○○の値が□□であり、仕様書P.x §x.xに記載の○○モードの上限を超過している」のように、
  必ず仕様書の該当箇所を根拠として引用すること
- 顧客への影響（事業上の意味）まで踏み込んで記述すること
- 推奨アクションは具体的に（「予防保全訪問」「冷却モジュール改修提案」等）

## 重要な制約
- 推測や憶測ではなく、仕様書に書かれていることを根拠にする
- 仕様書に該当センサーの記述がない場合は、関連する制御仕様・部品構成・メンテナンス仕様
  から類推可能な業務的影響を述べ、その旨（「仕様書に直接の閾値記載はないが、
  §x.x の○○仕様から類推すると」等）を明示する
- 全てのツール呼び出しが完了したら必ず write_equipment_alert を呼ぶこと
"""


def run_agent(
    event_payload: dict,
    sf_access_token: str,
    sf_instance_url: str,
    request_id: str,
) -> dict:
    """エージェントを起動してイベントを処理し、最終結果を返す。"""
    vertexai.init(project=GCP_PROJECT, location=VERTEX_LOCATION)
    storage_client = storage.Client(project=GCP_PROJECT)

    tool = Tool(function_declarations=FUNCTION_DECLARATIONS)
    model = GenerativeModel(
        VERTEX_MODEL,
        tools=[tool],
        system_instruction=SYSTEM_INSTRUCTION,
    )

    chat = model.start_chat()
    user_message = (
        "以下のIoT設備異常イベントを処理してください。"
        "必要なツールを順次呼び出して、Salesforceに診断結果を書き戻すまで実行してください。\n\n"
        f"イベントペイロード:\n{json.dumps(event_payload, ensure_ascii=False, indent=2)}"
    )

    log.info("[%s] agent start", request_id)
    response = chat.send_message(user_message)

    # ツール呼出ループ
    cached_pdf_part: Part | None = None
    cached_png_part: Part | None = None
    written_alert_id: str | None = None
    tool_history: list[dict] = []  # 各ツール呼出の履歴（フロントエンド表示用）
    iteration = 0
    max_iterations = 15

    while iteration < max_iterations:
        iteration += 1
        log.info("[%s] iteration %d", request_id, iteration)
        function_calls = []
        for cand in response.candidates:
            for part in cand.content.parts:
                fc = getattr(part, "function_call", None)
                if fc is not None and getattr(fc, "name", None):
                    function_calls.append(fc)

        if not function_calls:
            log.info("[%s] no more function calls. agent done.", request_id)
            break

        function_response_parts = []
        for fc in function_calls:
            fname = fc.name
            fargs = dict(fc.args) if fc.args else {}
            log.info("[%s] tool_call: %s args=%s", request_id, fname, fargs)
            tool_start = time.time()
            try:
                if fname == "get_asset_info":
                    result = tool_get_asset_info(fargs["asset_id"], sf_access_token, sf_instance_url)
                elif fname == "get_product_spec":
                    res = tool_get_product_spec(fargs["product_name"], storage_client)
                    if "pdfBytes" in res:
                        cached_pdf_part = Part.from_data(data=res.pop("pdfBytes"), mime_type="application/pdf")
                    result = res
                elif fname == "get_product_diagram":
                    res = tool_get_product_diagram(fargs["product_name"], storage_client)
                    if "pngBytes" in res:
                        cached_png_part = Part.from_data(data=res.pop("pngBytes"), mime_type="image/png")
                    result = res
                elif fname == "calculate_severity":
                    result = tool_calculate_severity(
                        float(fargs["value"]), float(fargs["threshold"]), fargs["sensor_type"]
                    )
                elif fname == "estimate_opportunity":
                    result = tool_estimate_opportunity(
                        float(fargs["asset_price"]), fargs["severity"], fargs["sensor_type"]
                    )
                elif fname == "write_equipment_alert":
                    result = tool_write_equipment_alert(
                        asset_id=fargs["asset_id"],
                        sensor_type=fargs["sensor_type"],
                        detected_value=float(fargs["detected_value"]),
                        threshold=float(fargs["threshold"]),
                        severity=fargs["severity"],
                        anomaly_description=fargs["anomaly_description"],
                        recommended_action=fargs["recommended_action"],
                        estimated_opportunity=int(fargs["estimated_opportunity"]),
                        opportunity_rationale=fargs.get("opportunity_rationale", ""),
                        sf_access_token=sf_access_token,
                        sf_instance_url=sf_instance_url,
                        request_id=request_id,
                    )
                    written_alert_id = result.get("alertId")
                else:
                    result = {"error": f"unknown tool: {fname}"}
            except Exception as e:
                log.exception("[%s] tool error: %s", request_id, fname)
                result = {"error": str(e)}

            elapsed = time.time() - tool_start
            tool_history.append({
                "tool": fname,
                "args": _summarize_args(fname, fargs),
                "result_summary": _summarize_result(fname, result),
                "elapsed_sec": round(elapsed, 2),
            })
            function_response_parts.append(
                Part.from_function_response(name=fname, response=result)
            )

        # PDFと画像が取得済みなら最初のツール応答に添付
        send_parts = list(function_response_parts)
        if cached_pdf_part is not None:
            send_parts.append(cached_pdf_part)
            cached_pdf_part = None  # 一度だけ送る
        if cached_png_part is not None:
            send_parts.append(cached_png_part)
            cached_png_part = None

        response = chat.send_message(send_parts)

    return {
        "alertId": written_alert_id,
        "iterations": iteration,
        "status": "completed" if written_alert_id else "incomplete",
        "toolHistory": tool_history,
    }


def _summarize_args(fname: str, fargs: dict) -> str:
    """ツール呼出引数を1行で要約（フロント表示用）"""
    if fname == "get_asset_info":
        return f"assetId={fargs.get('asset_id', '')[:18]}..."
    if fname in ("get_product_spec", "get_product_diagram"):
        return f"product={fargs.get('product_name', '')[:30]}"
    if fname == "calculate_severity":
        return f"value={fargs.get('value')} threshold={fargs.get('threshold')}"
    if fname == "estimate_opportunity":
        price = fargs.get("asset_price", 0)
        return f"price=¥{int(price):,} severity={fargs.get('severity')}"
    if fname == "write_equipment_alert":
        return f"severity={fargs.get('severity')} opportunity=¥{int(fargs.get('estimated_opportunity', 0)):,}"
    return ""


def _summarize_result(fname: str, result: dict) -> str:
    """ツール実行結果を1行で要約（フロント表示用）"""
    if isinstance(result, dict) and result.get("error"):
        return f"ERROR: {result['error']}"
    if fname == "get_asset_info":
        return f"{result.get('productName', '')} / {result.get('accountName', '')}"
    if fname == "get_product_spec":
        return f"PDF取得 {result.get('sizeBytes', 0):,} bytes"
    if fname == "get_product_diagram":
        return f"PNG取得 {result.get('sizeBytes', 0):,} bytes"
    if fname == "calculate_severity":
        return f"重要度: {result.get('severity', '')} ({result.get('reason', '')})"
    if fname == "estimate_opportunity":
        return f"¥{int(result.get('estimatedOpportunity', 0)):,}"
    if fname == "write_equipment_alert":
        return f"SF Record: {result.get('alertId', '')}"
    return ""
