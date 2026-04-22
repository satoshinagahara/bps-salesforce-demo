"""
Product Engineering Agent (RAG版 / Vertex AI Gemini Function Calling)

現行 product_engineering_agent.py と並走する検証用モジュール。差分:
  - get_product_spec / get_product_diagram / generate_signed_urls を廃止
  - retrieve_spec_chunks (BigQuery Vector Search) を追加
  - get_original_asset_url (LWCプレビュー用URL) を追加
  - マルチモーダル添付（PDF/PNGバイト）は廃止。テキストチャンクのみをcontextとして返す

既存のLWC/Apex/カスタムオブジェクトは一切変更しない。エンドポイントを別URL
(/design-suggestion-agent-rag, /equipment-alert-rag) で公開し、curlベースで検証する。
"""
from __future__ import annotations

import json
import logging
import os
import time
from datetime import datetime, timezone
from typing import Any

import requests as http_requests
import vertexai
from google.cloud import storage
from vertexai.generative_models import (
    FunctionDeclaration,
    GenerativeModel,
    Part,
    Tool,
)

# 既存エージェントから非RAG系ツールを流用（SF読取・書込、severity/opportunity計算）
from product_engineering_agent import (
    tool_get_initiative_info,
    tool_get_linked_needs,
    tool_get_asset_info,
    tool_calculate_severity,
    tool_estimate_opportunity,
    tool_write_design_suggestion,
    tool_write_equipment_alert,
)
from rag import get_document_asset_paths, retrieve_spec_chunks

log = logging.getLogger("product-engineering-agent-rag")
log.setLevel(logging.INFO)

GCP_PROJECT = os.environ.get("GCP_PROJECT", "ageless-lamp-251200")
VERTEX_LOCATION = os.environ.get("VERTEX_LOCATION", "us-central1")
VERTEX_MODEL = os.environ.get("VERTEX_MODEL", "gemini-2.5-flash")
GCS_BUCKET = os.environ.get("GCS_BUCKET", "bps-design-assets")


# ============================================================
# RAG 固有ツールの実装
# ============================================================

def tool_retrieve_spec_chunks(query: str, product_filter: str | None, top_k: int) -> dict:
    """BigQuery Vector Search で関連チャンクを取得。"""
    log.info("[tool] retrieve_spec_chunks: query_len=%d filter=%s top_k=%d",
             len(query), product_filter, top_k)
    # product_filter が "" や "none" は None として扱う
    if product_filter in ("", "none", "null", None):
        product_filter = None
    if top_k is None or top_k <= 0:
        top_k = 5
    return retrieve_spec_chunks(query=query, product_filter=product_filter, top_k=top_k)


def tool_get_original_asset_url(
    document_id: str,
    asset_type: str,
    storage_client: storage.Client,
) -> dict:
    """documents マスタから原本GCSパスを引き、Signed URL (1時間) を生成する。

    asset_type: 'spec' | 'diagram'
    """
    import google.auth
    from google.auth.transport import requests as auth_requests

    log.info("[tool] get_original_asset_url: doc=%s type=%s", document_id, asset_type)
    info = get_document_asset_paths(document_id)
    if "error" in info:
        return info

    if asset_type == "spec":
        gcs_path = info["spec_gcs_path"]
    elif asset_type == "diagram":
        diagrams = info.get("diagram_gcs_paths", [])
        if not diagrams:
            return {"error": f"no diagrams for {document_id}"}
        gcs_path = diagrams[0]
    else:
        return {"error": f"unknown asset_type: {asset_type}"}

    credentials, _ = google.auth.default()
    if hasattr(credentials, "refresh"):
        credentials.refresh(auth_requests.Request())
    sa_email = os.environ.get("SA_EMAIL", "bps-demo-sa@ageless-lamp-251200.iam.gserviceaccount.com")

    bucket = storage_client.bucket(GCS_BUCKET)
    blob = bucket.blob(gcs_path)
    url = blob.generate_signed_url(
        version="v4", expiration=3600, method="GET",
        service_account_email=sa_email,
        access_token=credentials.token,
    )
    return {"url": url, "gcs_path": gcs_path, "document_id": document_id, "asset_type": asset_type}


# ============================================================
# Function Calling スキーマ
# ============================================================

FUNCTION_DECLARATIONS = [
    FunctionDeclaration(
        name="get_initiative_info",
        description="Salesforceの製品施策（Product Initiative）レコードIDから施策情報（Why/What/ターゲット顧客/対象製品）を取得する。シナリオ1で使用",
        parameters={
            "type": "object",
            "properties": {"initiative_id": {"type": "string"}},
            "required": ["initiative_id"],
        },
    ),
    FunctionDeclaration(
        name="get_linked_needs",
        description="製品施策に紐付く顧客ニーズカード一覧を取得する。各ニーズの顧客の声・金額規模・優先度を含む。シナリオ1で使用",
        parameters={
            "type": "object",
            "properties": {"initiative_id": {"type": "string"}},
            "required": ["initiative_id"],
        },
    ),
    FunctionDeclaration(
        name="get_asset_info",
        description="SalesforceのAssetレコードIDから設備情報（製品名・取引先・納入価格・ステータス等）を取得する。シナリオ2で使用",
        parameters={
            "type": "object",
            "properties": {"asset_id": {"type": "string"}},
            "required": ["asset_id"],
        },
    ),
    FunctionDeclaration(
        name="retrieve_spec_chunks",
        description=(
            "製品仕様書および図面の構造化キャプションを格納したベクトルDBに対して、"
            "ニーズ文や異常イベントに最も関連する上位チャンクを取得する。"
            "\n\n【使い方】"
            "\n  query: 施策のTitle/Why/What/ターゲット顧客/対象製品と、紐付くニーズ群のCustomer_Voice/Descriptionを連結した自然言語。"
            "シナリオ2では sensorType + 検知値 + 閾値 + 製品名 + 設置環境 等を連結。"
            "\n  product_filter: 'a1000'（風力タービン） / 'e2000'（蓄電システム）。対象製品が判明している場合は必ず指定して検索精度を高めること。不明なら省略可。"
            "\n  top_k: 5 を既定とする。"
            "\n\n【戻り値】"
            "\n  chunks: 上位チャンクのリスト（section/page/text/distance/related_figure_ids）。"
            "\n  expanded_figures: specヒットチャンクの related_figure_ids を辿って展開した図面チャンク。"
            "\n\n重要: これは仕様書と図面の両方をカバーする唯一のリトリーブ手段である。"
        ),
        parameters={
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "検索クエリ（施策＋ニーズの連結 or 異常イベント説明）"},
                "product_filter": {"type": "string", "enum": ["a1000", "e2000"],
                                   "description": "対象製品のdocument_id。指定で精度向上"},
                "top_k": {"type": "integer", "description": "上位N件。既定5"},
            },
            "required": ["query"],
        },
    ),
    FunctionDeclaration(
        name="get_original_asset_url",
        description=(
            "仕様書PDFまたは図面PNGの**原本**Signed URL（1時間有効）を取得する。"
            "LWCプレビュー画面に埋め込むためのURLで、リトリーブで特定した document_id を渡す。"
            "write_design_suggestion の前に必ず呼び、返却された URL を LWC に渡すためレスポンスへ反映する。"
        ),
        parameters={
            "type": "object",
            "properties": {
                "document_id": {"type": "string", "enum": ["a1000", "e2000"]},
                "asset_type": {"type": "string", "enum": ["spec", "diagram"]},
            },
            "required": ["document_id", "asset_type"],
        },
    ),
    FunctionDeclaration(
        name="calculate_severity",
        description="センサー検知値と閾値から異常の重要度（高/中/低）を判定する。シナリオ2で使用",
        parameters={
            "type": "object",
            "properties": {
                "value": {"type": "number"},
                "threshold": {"type": "number"},
                "sensor_type": {"type": "string"},
            },
            "required": ["value", "threshold", "sensor_type"],
        },
    ),
    FunctionDeclaration(
        name="estimate_opportunity",
        description="設備の納入価格と重要度から想定商談機会金額を試算する。シナリオ2で使用",
        parameters={
            "type": "object",
            "properties": {
                "asset_price": {"type": "number"},
                "severity": {"type": "string", "enum": ["高", "中", "低"]},
                "sensor_type": {"type": "string"},
            },
            "required": ["asset_price", "severity", "sensor_type"],
        },
    ),
    FunctionDeclaration(
        name="write_design_suggestion",
        description=(
            "全ての分析が完了したら最後にこの関数を呼び、DesignSuggestion__c に設計改善提案を書き戻す。"
            "suggestion_text は取得したチャンクのセクション番号（例: P.3 §3.2）を必ず引用して3〜5文。"
            "reference_spec は仕様書該当箇所（例: 'P.3 §3.2 風速域別の制御モード / P.3 §3.4 既知の設計課題'）。"
            "reference_diagram は図面タイトル（例: 'Fig.1 ブレードピッチ制御機構 配置図'）。"
        ),
        parameters={
            "type": "object",
            "properties": {
                "initiative_id": {"type": "string"},
                "target_product": {"type": "string"},
                "target_component": {"type": "string"},
                "suggestion_text": {"type": "string"},
                "reference_spec": {"type": "string"},
                "reference_diagram": {"type": "string"},
                "priority": {"type": "string", "enum": ["高", "中", "低"]},
            },
            "required": [
                "initiative_id", "target_product", "target_component",
                "suggestion_text", "reference_spec", "reference_diagram", "priority",
            ],
        },
    ),
    FunctionDeclaration(
        name="write_equipment_alert",
        description=(
            "全ての分析が完了したら最後にこの関数を呼び、Equipment_Alert__c に診断結果を書き戻す。"
            "anomaly_description はヒットした仕様書セクションを引用しながら3〜5文。"
            "recommended_action は箇条書き（行頭'・'）で2〜4項目。"
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
                "opportunity_rationale": {"type": "string"},
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
# System Instructions (RAG版)
# ============================================================

SYSTEM_INSTRUCTION_DESIGN_SUGGESTION = """\
あなたは BPS Corporation の Product Engineering Agent (RAG版) です。
顧客ニーズから起案された製品施策に対し、製品仕様書と設計図面を格納したベクトルDB
（BigQuery Vector Search）から関連セクションをretrieveし、具体的な設計改善提案を生成します。

## 入力
製品施策レコードID（initiativeId）

## 手順
1. get_initiative_info で施策情報（Title/Why/What/Target/対象製品）を取得
2. get_linked_needs で紐付くニーズカード群を取得
3. retrieve_spec_chunks で関連チャンクを取得する
   - query: 施策Title + Why + What + ターゲット顧客 + 対象製品 + 全ニーズの Customer_Voice と Description
     をまとまった日本語テキストとして連結する
   - product_filter: 対象製品名から 'a1000'（風力タービン）または 'e2000'（蓄電/EnerCharge/バッテリー）を判別して必ず指定
   - top_k: 5
4. リトリーブ結果 (chunks + expanded_figures) を熟読し、施策とニーズ群に合致する
   設計改善提案を策定する
   - ヒットチャンクのsection番号を必ず suggestion_text / reference_spec に引用
   - 「既知課題」セクション（§3.4）が含まれていれば優先して根拠に使う
   - expanded_figures に展開された図面が提案に関連すれば reference_diagram に図面タイトルを記載
5. get_original_asset_url で document_id の原本仕様書PDF（asset_type='spec'）と
   原本図面PNG（asset_type='diagram'）のSigned URLを取得
6. write_design_suggestion で Salesforce に提案を書き戻す
7. 完了応答を返す

## 提案テキストのスタイル
- 取得したチャンクのsection番号とsection_titleを具体的に引用（例: "§3.2 風速域別の制御モード によれば、起動モード(3.5〜5.0 m/s)は発電効率最適化対象外である"）
- 「どの製品のどの部分をどう変えるべきか」を明記
- 複数ニーズを統合した1つの提案にまとめる
- 3〜5文で簡潔に

## 重要な制約
- 仕様書に書かれていない内容（推測・憶測）は提案に含めない
- retrieve_spec_chunks を呼ばずに提案を作ることは禁止。必ずRAGの結果に基づくこと
- 全てのツール呼出が完了したら必ず write_design_suggestion を呼ぶこと
"""


SYSTEM_INSTRUCTION_EQUIPMENT_ALERT = """\
あなたは BPS Corporation の Product Engineering Agent (RAG版) です。
IoT設備異常イベントを受け取り、製品仕様書のベクトルDB（BigQuery Vector Search）から
関連セクションをretrieveして、業務的な解釈をSalesforceに届けます。

## 入力
{"assetId": "...", "sensorType": "セル温度", "value": 47.5, "threshold": 45.0, "location": "..."}

## 手順
1. get_asset_info でAsset情報（製品名・取引先・設置場所・納入価格）を取得
2. retrieve_spec_chunks で異常イベントに関連するチャンクを取得する
   - query: sensor_type + 検知値 + 閾値 + 超過率(%) + 製品名 + 設置ロケーション + 「異常判定」「既知課題」等
   - product_filter: 対象製品名から 'a1000' / 'e2000' を必ず判別して指定
   - top_k: 5
3. calculate_severity で重要度を判定
4. estimate_opportunity で想定商談機会金額を試算
5. リトリーブ結果を根拠に、検知値が業務的に何を意味するか診断する
   - ヒットしたsection番号（§3.2 温度管理モード等）を必ず引用
   - §3.4 既知設計課題に該当性があるか検証
6. write_equipment_alert で Salesforce に診断結果を書き戻す
   - opportunity_rationale には estimate_opportunity の rationale をそのまま

## 診断テキストのスタイル
- 「センサー値〇〇が閾値△△を□□%超過している。仕様書§x.x によれば高温注意モードは…」
- 顧客への事業上の影響まで踏み込む
- 推奨アクションは具体的に（「予防保全訪問」「冷却モジュール改修提案」等）

## 重要な制約
- 推測や憶測ではなく、retrieveしたチャンクに書かれていることを根拠にする
- retrieve_spec_chunks を呼ばずに診断することは禁止
- 全てのツール呼出が完了したら必ず write_equipment_alert を呼ぶこと
"""


# ============================================================
# Agent Runtime
# ============================================================

def run_agent_rag(
    event_payload: dict,
    sf_access_token: str,
    sf_instance_url: str,
    request_id: str,
    mode: str = "equipment_alert",
) -> dict:
    """RAG版エージェントを起動してイベント/リクエストを処理し、最終結果を返す。

    mode:
      - 'equipment_alert': シナリオ2
      - 'design_suggestion': シナリオ1
    """
    started_at = datetime.now(timezone.utc)
    run_start = time.time()
    vertexai.init(project=GCP_PROJECT, location=VERTEX_LOCATION)
    storage_client = storage.Client(project=GCP_PROJECT)
    tool_history: list[dict] = []
    token_usage: dict = {"prompt": 0, "output": 0, "total": 0, "gemini_calls": 0}

    try:
        return _run_inner(
            event_payload=event_payload,
            sf_access_token=sf_access_token,
            sf_instance_url=sf_instance_url,
            request_id=request_id,
            mode=mode,
            started_at=started_at,
            run_start=run_start,
            storage_client=storage_client,
            tool_history=tool_history,
            token_usage=token_usage,
        )
    except Exception as e:
        elapsed_sec = round(time.time() - run_start, 2)
        _persist_run_log(
            storage_client=storage_client,
            request_id=request_id,
            mode=mode,
            event_payload=event_payload,
            started_at=started_at,
            elapsed_sec=elapsed_sec,
            iterations=len(tool_history),
            tool_history=tool_history,
            status="error",
            result={},
            error=str(e),
            token_usage=token_usage,
        )
        raise


def _run_inner(
    *,
    event_payload: dict,
    sf_access_token: str,
    sf_instance_url: str,
    request_id: str,
    mode: str,
    started_at: datetime,
    run_start: float,
    storage_client: storage.Client,
    tool_history: list[dict],
    token_usage: dict,
) -> dict:
    if mode == "design_suggestion":
        system_instruction = SYSTEM_INSTRUCTION_DESIGN_SUGGESTION
        user_message = (
            "以下の製品施策に対する設計改善提案をRAG経由で生成してください。"
            "必要なツールを順次呼び、最後に write_design_suggestion を呼んでください。\n\n"
            f"入力:\n{json.dumps(event_payload, ensure_ascii=False, indent=2)}"
        )
    else:
        system_instruction = SYSTEM_INSTRUCTION_EQUIPMENT_ALERT
        user_message = (
            "以下のIoT設備異常イベントをRAG経由で処理してください。"
            "最後に write_equipment_alert を呼んでください。\n\n"
            f"イベント:\n{json.dumps(event_payload, ensure_ascii=False, indent=2)}"
        )

    tool = Tool(function_declarations=FUNCTION_DECLARATIONS)
    model = GenerativeModel(VERTEX_MODEL, tools=[tool], system_instruction=system_instruction)
    chat = model.start_chat()

    log.info("[%s] rag agent start (mode=%s)", request_id, mode)
    response = chat.send_message(user_message)
    _accumulate_usage(token_usage, response)

    written_alert_id: str | None = None
    written_suggestion_id: str | None = None
    design_result: dict = {}

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
            log.info("[%s] tool_call: %s args=%s", request_id, fname,
                     {k: (v[:80] + "...") if isinstance(v, str) and len(v) > 80 else v
                      for k, v in fargs.items()})
            tool_start = time.time()
            try:
                result = _dispatch_tool(
                    fname=fname,
                    fargs=fargs,
                    sf_access_token=sf_access_token,
                    sf_instance_url=sf_instance_url,
                    storage_client=storage_client,
                    request_id=request_id,
                )

                # 成果物を design_result に反映
                if fname == "get_original_asset_url" and isinstance(result, dict) and "url" in result:
                    if result.get("asset_type") == "spec":
                        design_result["specUrl"] = result["url"]
                    elif result.get("asset_type") == "diagram":
                        design_result["diagramUrl"] = result["url"]
                elif fname == "write_design_suggestion":
                    written_suggestion_id = result.get("designSuggestionId")
                    design_result.update({
                        "designSuggestionId": written_suggestion_id,
                        "targetProduct": fargs.get("target_product"),
                        "targetComponent": fargs.get("target_component"),
                        "suggestionText": fargs.get("suggestion_text"),
                        "referenceSpec": fargs.get("reference_spec"),
                        "referenceDiagram": fargs.get("reference_diagram"),
                        "priority": fargs.get("priority"),
                    })
                elif fname == "write_equipment_alert":
                    written_alert_id = result.get("alertId")

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
                Part.from_function_response(name=fname, response=_prune_result_for_model(fname, result))
            )

        response = chat.send_message(function_response_parts)
        _accumulate_usage(token_usage, response)

    elapsed_sec = round(time.time() - run_start, 2)
    if mode == "design_suggestion":
        design_result["processedBy"] = f"Vertex AI {VERTEX_MODEL} (RAG Agent)"
        design_result["generatedAt"] = datetime.now(timezone.utc).astimezone().isoformat()
        design_result["gcpRequestId"] = request_id
        status = "completed" if written_suggestion_id else "incomplete"
        result = {
            **design_result,
            "iterations": iteration,
            "status": status,
            "toolHistory": tool_history,
        }
    else:
        status = "completed" if written_alert_id else "incomplete"
        result = {
            "alertId": written_alert_id,
            "iterations": iteration,
            "status": status,
            "toolHistory": tool_history,
        }

    _persist_run_log(
        storage_client=storage_client,
        request_id=request_id,
        mode=mode,
        event_payload=event_payload,
        started_at=started_at,
        elapsed_sec=elapsed_sec,
        iterations=iteration,
        tool_history=tool_history,
        status=status,
        result=result,
        token_usage=token_usage,
    )
    result["tokenUsage"] = token_usage
    return result


def _dispatch_tool(
    *,
    fname: str,
    fargs: dict,
    sf_access_token: str,
    sf_instance_url: str,
    storage_client: storage.Client,
    request_id: str,
) -> dict:
    if fname == "get_initiative_info":
        return tool_get_initiative_info(fargs["initiative_id"], sf_access_token, sf_instance_url)
    if fname == "get_linked_needs":
        return tool_get_linked_needs(fargs["initiative_id"], sf_access_token, sf_instance_url)
    if fname == "get_asset_info":
        return tool_get_asset_info(fargs["asset_id"], sf_access_token, sf_instance_url)
    if fname == "retrieve_spec_chunks":
        top_k_raw = fargs.get("top_k", 5)
        try:
            top_k = int(top_k_raw) if top_k_raw is not None else 5
        except (TypeError, ValueError):
            top_k = 5
        return tool_retrieve_spec_chunks(
            query=fargs.get("query", ""),
            product_filter=fargs.get("product_filter"),
            top_k=top_k,
        )
    if fname == "get_original_asset_url":
        return tool_get_original_asset_url(
            document_id=fargs["document_id"],
            asset_type=fargs["asset_type"],
            storage_client=storage_client,
        )
    if fname == "calculate_severity":
        return tool_calculate_severity(
            float(fargs["value"]), float(fargs["threshold"]), fargs["sensor_type"]
        )
    if fname == "estimate_opportunity":
        return tool_estimate_opportunity(
            float(fargs["asset_price"]), fargs["severity"], fargs["sensor_type"]
        )
    if fname == "write_design_suggestion":
        return tool_write_design_suggestion(
            initiative_id=fargs["initiative_id"],
            target_product=fargs["target_product"],
            target_component=fargs["target_component"],
            suggestion_text=fargs["suggestion_text"],
            reference_spec=fargs["reference_spec"],
            reference_diagram=fargs["reference_diagram"],
            priority=fargs["priority"],
            sf_access_token=sf_access_token,
            sf_instance_url=sf_instance_url,
            request_id=request_id,
        )
    if fname == "write_equipment_alert":
        return tool_write_equipment_alert(
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
    return {"error": f"unknown tool: {fname}"}


def _prune_result_for_model(fname: str, result: Any) -> Any:
    """Gemini に返すツール結果を必要な情報に絞る。retrieve_spec_chunks は text が長いので通過させるが
    distance を float 化、expanded_figures の text は先頭 1500 文字に丸める等の軽い正規化のみ。"""
    if not isinstance(result, dict):
        return result
    if fname == "retrieve_spec_chunks":
        # 長いテキストが複数含まれると prompt が膨らむため figure expansion は短くする
        expanded = result.get("expanded_figures", []) or []
        for f in expanded:
            if isinstance(f.get("text"), str) and len(f["text"]) > 1500:
                f["text"] = f["text"][:1500] + "…（省略）"
    return result


def _accumulate_usage(acc: dict, response) -> None:
    try:
        um = getattr(response, "usage_metadata", None)
        if um is None:
            return
        acc["prompt"] += int(getattr(um, "prompt_token_count", 0) or 0)
        acc["output"] += int(getattr(um, "candidates_token_count", 0) or 0)
        acc["total"] += int(getattr(um, "total_token_count", 0) or 0)
        acc["gemini_calls"] += 1
    except Exception:
        pass


def _persist_run_log(
    *,
    storage_client: storage.Client,
    request_id: str,
    mode: str,
    event_payload: dict,
    started_at: datetime,
    elapsed_sec: float,
    iterations: int,
    tool_history: list[dict],
    status: str,
    result: dict,
    error: str | None = None,
    token_usage: dict | None = None,
) -> None:
    try:
        tool_names = [t.get("tool") for t in tool_history if t.get("tool")]
        target_id = event_payload.get("initiativeId") or event_payload.get("assetId") or ""
        summary = {
            "request_id": request_id,
            "mode": mode,
            "variant": "rag",
            "target_id": target_id,
            "started_at": started_at.isoformat(),
            "elapsed_sec": elapsed_sec,
            "iterations": iterations,
            "tool_count": len(tool_history),
            "unique_tools": sorted(set(tool_names)),
            "tool_history": tool_history,
            "status": status,
            "gemini_model": VERTEX_MODEL,
            "token_usage": token_usage or {"prompt": 0, "output": 0, "total": 0, "gemini_calls": 0},
            "written_record_id": result.get("designSuggestionId") or result.get("alertId"),
            "error": error,
        }
        path = (
            f"runs-rag/{started_at.strftime('%Y-%m-%d')}/"
            f"{started_at.strftime('%Y%m%dT%H%M%SZ')}_{request_id}.json"
        )
        blob = storage_client.bucket(GCS_BUCKET).blob(path)
        blob.upload_from_string(
            json.dumps(summary, ensure_ascii=False, indent=2),
            content_type="application/json; charset=utf-8",
        )
        log.info("[%s] rag run log persisted: gs://%s/%s", request_id, GCS_BUCKET, path)
    except Exception as e:
        log.warning("[%s] rag run log persist failed: %s", request_id, e)


def _summarize_args(fname: str, fargs: dict) -> str:
    if fname == "retrieve_spec_chunks":
        q = fargs.get("query", "")
        q_short = q[:40] + "..." if len(q) > 40 else q
        return f"filter={fargs.get('product_filter', '-')} top_k={fargs.get('top_k', 5)} q='{q_short}'"
    if fname == "get_original_asset_url":
        return f"doc={fargs.get('document_id')} type={fargs.get('asset_type')}"
    if fname == "get_initiative_info":
        return f"initiativeId={fargs.get('initiative_id', '')[:18]}..."
    if fname == "get_linked_needs":
        return f"initiativeId={fargs.get('initiative_id', '')[:18]}..."
    if fname == "get_asset_info":
        return f"assetId={fargs.get('asset_id', '')[:18]}..."
    if fname == "calculate_severity":
        return f"value={fargs.get('value')} threshold={fargs.get('threshold')}"
    if fname == "estimate_opportunity":
        price = fargs.get("asset_price", 0)
        return f"price=¥{int(price):,} severity={fargs.get('severity')}"
    if fname == "write_design_suggestion":
        return f"product={fargs.get('target_product', '')[:20]} priority={fargs.get('priority')}"
    if fname == "write_equipment_alert":
        return f"severity={fargs.get('severity')} opportunity=¥{int(fargs.get('estimated_opportunity', 0)):,}"
    return ""


def _summarize_result(fname: str, result: Any) -> str:
    if isinstance(result, dict) and result.get("error"):
        return f"ERROR: {result['error']}"
    if fname == "retrieve_spec_chunks":
        chunks = (result or {}).get("chunks", [])
        exp = (result or {}).get("expanded_figures", [])
        if not chunks:
            return "0 hits"
        top = chunks[0]
        label = top.get("section_title") or top.get("figure_title") or ""
        return (f"{len(chunks)} hits (+{len(exp)} figs) | top: "
                f"{top.get('document_id')}/§{top.get('section') or top.get('figure_id')} "
                f"{label} d={top.get('distance')}")
    if fname == "get_original_asset_url":
        return f"{result.get('asset_type')} URL for {result.get('document_id')}"
    if fname == "get_initiative_info":
        return f"{result.get('title', '')} (対象製品: {result.get('productName', '')})"
    if fname == "get_linked_needs":
        return f"ニーズ {result.get('needsCount', 0)}件 取得"
    if fname == "get_asset_info":
        return f"{result.get('productName', '')} / {result.get('accountName', '')}"
    if fname == "calculate_severity":
        return f"重要度: {result.get('severity', '')} ({result.get('reason', '')})"
    if fname == "estimate_opportunity":
        return f"¥{int(result.get('estimatedOpportunity', 0)):,}"
    if fname == "write_design_suggestion":
        return f"SF Record: {result.get('designSuggestionId', '')}"
    if fname == "write_equipment_alert":
        return f"SF Record: {result.get('alertId', '')}"
    return ""
