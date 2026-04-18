"""Agentforce 2.0 - Gradio UI

ローカル Gemma 4 + Multi-MCP エージェントの対話UI。
- Chat パネル: ストリーミング + tool 呼び出しを collapsible メタデータで可視化
- サイドバー: モデル / MCP サーバ / プロファイル情報

起動:
    cd agentforce2
    uv run python -m app.gradio_app
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from pathlib import Path
from typing import Any

import gradio as gr
import yaml
from dotenv import load_dotenv

from agent.loop import (
    AgentConfig,
    AgentLoop,
    EvAssistantText,
    EvFinish,
    EvToolCallResult,
    EvToolCallStart,
)
from agent.mcp_manager import MCPManager, MCPServerSpec

load_dotenv()
logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
logger = logging.getLogger("gradio_app")

ROOT = Path(__file__).resolve().parents[1]
PROFILE_PATH = Path(os.environ.get("USER_PROFILE_PATH", ROOT / "config" / "user_profile.yaml"))

WORK_PATTERN_CHOICES = [
    ("オフィス出社 (office)", "office"),
    ("在宅 (home)", "home"),
    ("柔軟 (flexible)", "flexible"),
]

# ---- MCP manager (プロセス全体で共有・遅延起動) ----
_mgr: MCPManager | None = None
_agent: AgentLoop | None = None
_init_lock = asyncio.Lock()


def _google_creds_ok() -> bool:
    p = Path(os.environ.get(
        "GOOGLE_OAUTH_CREDENTIALS", ROOT / "config" / "tokens" / "google_credentials.json"
    ))
    return p.exists()


def _sf_username() -> str | None:
    """メインプロジェクトの sf-config.json から target org username を読む。"""
    cfg_path = Path(os.environ.get(
        "SF_CONFIG_PATH", ROOT.parent / "sf-config.json"
    ))
    if not cfg_path.exists():
        return None
    try:
        return json.loads(cfg_path.read_text(encoding="utf-8")).get("username")
    except Exception as e:
        logger.warning(f"failed to read sf-config.json: {e}")
        return None


# MCP プロファイル定義
# Gemma 4 26B A4B 4bit は同時ロード 20 tools 未満が安全圏（実測: 25 tools で tool_call 崩壊）。
# 用途別に起動時選択する運用とし、動的ロードは Phase 3 以降で検討。
MCP_PROFILES: dict[str, list[str]] = {
    "sales":   ["sf", "gw", "fetch", "time"],               # 11 tools — 営業支援（SSoT + カレンダー/メール + Web + 時刻）
    "minimal": ["sf", "fetch", "time"],                     # 7 tools  — SSoT 単独検証用
    "full":    ["sf", "gw", "fetch", "time", "fs", "memory"],  # 34 tools — 動作検証用（壊れる想定）
}
DEFAULT_PROFILE = "sales"


def _current_specs() -> list[MCPServerSpec]:
    profile_name = os.environ.get("AGENT_MCP_PROFILE", DEFAULT_PROFILE)
    allow = set(MCP_PROFILES.get(profile_name, MCP_PROFILES[DEFAULT_PROFILE]))
    if profile_name not in MCP_PROFILES:
        logger.warning(f"unknown AGENT_MCP_PROFILE={profile_name!r}, using {DEFAULT_PROFILE}")
        profile_name = DEFAULT_PROFILE
    logger.info(f"AGENT_MCP_PROFILE={profile_name} → {sorted(allow)}")

    specs: list[MCPServerSpec] = []

    # 公式 Salesforce MCP (@salesforce/mcp) — sf CLI 認証を参照
    if "sf" in allow:
        sf_user = _sf_username()
        if sf_user:
            specs.append(MCPServerSpec(
                name="sf",
                command="npx",
                args=[
                    "-y", "@salesforce/mcp",
                    "--orgs", sf_user,
                    "--toolsets", "core,data,orgs",
                    "--no-telemetry",
                ],
            ))
        else:
            logger.warning("sf-config.json not found or missing username; sf MCP disabled")

    if "gw" in allow and _google_creds_ok():
        specs.append(MCPServerSpec(name="gw", module="mcp_servers.google_mcp"))

    # 公式 Anthropic reference MCP: 汎用 HTTP fetch
    if "fetch" in allow:
        specs.append(MCPServerSpec(name="fetch", command="uvx", args=["mcp-server-fetch"]))

    # 公式 Anthropic reference MCP: 現在時刻・TZ 変換
    if "time" in allow:
        specs.append(MCPServerSpec(name="time", command="uvx", args=["mcp-server-time"]))

    # 公式 Anthropic reference MCP: ローカルファイル操作（スコープを workspace/ に限定）
    if "fs" in allow:
        workspace_path = ROOT / "workspace"
        workspace_path.mkdir(exist_ok=True)
        specs.append(MCPServerSpec(
            name="fs",
            command="npx",
            args=["-y", "@modelcontextprotocol/server-filesystem", str(workspace_path)],
        ))

    # 公式 Anthropic reference MCP: 知識グラフ形式の永続メモリ
    if "memory" in allow:
        memory_path = ROOT / "data" / "memory.json"
        memory_path.parent.mkdir(exist_ok=True)
        specs.append(MCPServerSpec(
            name="memory",
            command="npx",
            args=["-y", "@modelcontextprotocol/server-memory"],
            env={"MEMORY_FILE_PATH": str(memory_path)},
        ))
    return specs


async def _ensure_initialized():
    global _mgr, _agent
    async with _init_lock:
        if _mgr is None:
            specs = _current_specs()
            logger.info(f"Starting MCP manager with: {[s.name for s in specs]}")
            mgr = MCPManager(specs)
            await mgr.__aenter__()
            _mgr = mgr
            _agent = AgentLoop(_mgr, cfg=AgentConfig())
    return _mgr, _agent


# ---- Chat handler ----
async def chat_fn(message: str, history: list[dict]):
    """Gradio ChatInterface generator (type='messages')."""
    if not message or not message.strip():
        yield []
        return

    mgr, agent = await _ensure_initialized()

    # 既存履歴をLLM用履歴に変換（metadata 付きのtool行はskip）
    llm_history = [
        {"role": h["role"], "content": h["content"]}
        for h in history
        if isinstance(h, dict) and not (h.get("metadata") or {}).get("title")
        and h.get("content")
    ]

    # 画面用の messages — 今ターンで追加する assistant メッセージのみを yield する。
    # ChatInterface(type="messages") は yield された list を現ターンの応答として
    # 履歴末尾に追加表示するため、list(history) から始めると履歴が重複描画される。
    messages: list[dict] = []
    # 見た目のplaceholder（thinking）
    thinking_idx = len(messages)
    messages.append({
        "role": "assistant",
        "content": "",
        "metadata": {"title": "🤔 考えています…", "status": "pending", "id": "thinking"},
    })
    yield messages

    pending_tools: dict[str, dict] = {}  # id → {idx, name, start_time}
    assistant_text_idx: int | None = None
    thinking_removed = False

    async for ev in agent.run(message, llm_history):
        # 最初のイベントで thinking を消す
        if not thinking_removed:
            messages.pop(thinking_idx)
            thinking_removed = True

        if isinstance(ev, EvToolCallStart):
            args_str = json.dumps(ev.arguments, ensure_ascii=False, indent=2)
            if len(args_str) > 400:
                args_str = args_str[:400] + "\n…(truncated)"
            messages.append({
                "role": "assistant",
                "content": f"```json\n{args_str}\n```",
                "metadata": {
                    "title": f"🔧 {ev.name}",
                    "status": "pending",
                    "id": f"tool-{ev.id}",
                },
            })
            pending_tools[ev.id] = {"idx": len(messages) - 1, "start": time.time()}
            yield messages

        elif isinstance(ev, EvToolCallResult):
            entry = pending_tools.get(ev.id)
            if entry is None:
                continue
            elapsed = time.time() - entry["start"]
            idx = entry["idx"]
            prev_content = messages[idx]["content"]
            title = f"{'❌' if ev.is_error else '✅'} {ev.name} ({elapsed:.1f}s)"
            preview = ev.result_summary
            if len(preview) > 1200:
                preview = preview[:1200] + "\n…(truncated)"
            messages[idx] = {
                "role": "assistant",
                "content": prev_content + f"\n\n**Result:**\n```\n{preview}\n```",
                "metadata": {
                    "title": title,
                    "status": "done",
                    "id": f"tool-{ev.id}",
                },
            }
            yield messages

        elif isinstance(ev, EvAssistantText):
            if assistant_text_idx is None:
                messages.append({"role": "assistant", "content": ev.text})
                assistant_text_idx = len(messages) - 1
            else:
                messages[assistant_text_idx]["content"] += ev.text
            yield messages

        elif isinstance(ev, EvFinish):
            # thinking が最後まで残っていた場合の保険（元々消してるが）
            if not thinking_removed:
                messages.pop(thinking_idx)
            # 最終メッセージがなければ簡潔なものを追加
            if assistant_text_idx is None and not any(
                m.get("role") == "assistant" and not (m.get("metadata") or {}).get("title")
                for m in messages[-5:]
            ):
                messages.append({"role": "assistant", "content": "_(完了)_"})
            yield messages


# ---- Profile IO ----
def _load_profile_raw() -> dict:
    if not PROFILE_PATH.exists():
        return {}
    return yaml.safe_load(PROFILE_PATH.read_text(encoding="utf-8")) or {}


def _save_profile_yaml(
    name, role, email,
    office_label, office_addr,
    home_label, home_addr,
    mon, tue, wed, thu, fri, sat, sun,
    hours_start, hours_end,
    buffer_before, buffer_after,
):
    data = {
        "user": {
            "name": (name or "").strip(),
            "email": (email or "").strip(),
            "role": (role or "").strip(),
        },
        "locations": {
            "office": {"label": (office_label or "").strip(), "address": (office_addr or "").strip()},
            "home": {"label": (home_label or "").strip(), "address": (home_addr or "").strip()},
        },
        "work_pattern": {
            "monday": mon, "tuesday": tue, "wednesday": wed,
            "thursday": thu, "friday": fri, "saturday": sat, "sunday": sun,
        },
        "working_hours": {
            "start": (hours_start or "09:00").strip(),
            "end": (hours_end or "18:00").strip(),
        },
        "visit_buffer": {
            "before": int(buffer_before or 0),
            "after": int(buffer_after or 0),
        },
    }
    PROFILE_PATH.write_text(
        yaml.safe_dump(data, allow_unicode=True, sort_keys=False),
        encoding="utf-8",
    )
    ts = time.strftime("%H:%M:%S")
    logger.info(f"user_profile saved at {ts}")
    return f"✅ 保存しました ({ts})", _profile_markdown()


# ---- Sidebar content ----
def _profile_markdown() -> str:
    if not PROFILE_PATH.exists():
        return "_(user_profile.yaml 未設定)_"
    p = yaml.safe_load(PROFILE_PATH.read_text(encoding="utf-8")) or {}
    u = p.get("user", {})
    locs = p.get("locations", {})
    off = locs.get("office", {})
    hm = locs.get("home", {})
    wp = p.get("work_pattern", {})
    wh = p.get("working_hours", {})
    vb = p.get("visit_buffer", {})
    lines = [f"**{u.get('name', '-')}** / {u.get('role', '-')}"]
    lines.append(f"- 🏢 {off.get('label', 'オフィス')}: {off.get('address', '-')}")
    lines.append(f"- 🏠 {hm.get('label', '自宅')}: {hm.get('address', '-')}")
    wp_str = " / ".join(f"{k[:3]}:{v}" for k, v in wp.items())
    lines.append(f"- 📅 {wp_str}")
    lines.append(f"- 🕒 営業時間: {wh.get('start', '-')}〜{wh.get('end', '-')}")
    lines.append(f"- ⏱ バッファ: 前{vb.get('before', '-')}分 / 後{vb.get('after', '-')}分")
    return "\n".join(lines)


def _status_markdown() -> str:
    cfg = AgentConfig()
    mlx_ok = _probe_mlx(cfg.base_url)
    sf_ok = (ROOT.parent / "sf-config.json").exists()
    gw_ok = _google_creds_ok()
    parts = [
        f"**Model**: `{cfg.model}`",
        f"- mlx-lm: {'🟢' if mlx_ok else '🔴'} {cfg.base_url}",
        f"- Salesforce MCP (公式): {'🟢' if sf_ok else '🔴'}",
        f"- Google Workspace MCP (自作): {'🟢' if gw_ok else '🟡 未設定'}",
        f"- fetch / time / filesystem / memory MCP (公式): 🟢",
    ]
    return "\n".join(parts)


def _probe_mlx(base_url: str) -> bool:
    import httpx
    try:
        r = httpx.get(f"{base_url}/models", timeout=2)
        return r.status_code == 200
    except Exception:
        return False


def _tools_markdown() -> str:
    global _mgr
    if _mgr is None:
        return "_(起動後に表示されます)_"
    sf_tools = [t.original_name for t in _mgr.tools if t.server == "sf"]
    gw_tools = [t.original_name for t in _mgr.tools if t.server == "gw"]
    lines = []
    if sf_tools:
        lines.append("**Salesforce**")
        for t in sf_tools:
            lines.append(f"- `{t}`")
    if gw_tools:
        lines.append("\n**Google Workspace**")
        for t in gw_tools:
            lines.append(f"- `{t}`")
    return "\n".join(lines) if lines else "_(no tools)_"


# ---- UI ----
EXAMPLES = [
    "今四半期の優先商談トップ3を教えて",
    "今四半期で一番優先すべき商談を1つ選んで、その取引先責任者の連絡先と住所を教えて",
    "明日・明後日の商談アポに空き時間はある？",
    "最優先商談の取引先責任者にアポを取るための候補日時を3つ提案して",
]


def build_demo() -> gr.Blocks:
    with gr.Blocks(
        title="Agentforce 2.0",
        fill_height=True,
    ) as demo:
        with gr.Row():
            with gr.Column(scale=3):
                gr.Markdown("# 🤖 Agentforce 2.0\n_Local Gemma 4 + Multi-MCP_")
                chatbot = gr.Chatbot(
                    height=620,
                    buttons=["copy", "copy_all"],
                    layout="panel",
                )
                chat = gr.ChatInterface(
                    fn=chat_fn,
                    chatbot=chatbot,
                    examples=EXAMPLES,
                    title=None,
                )

            with gr.Column(scale=1, min_width=280):
                gr.Markdown("### 🟢 Status")
                status_md = gr.Markdown(_status_markdown())
                refresh_btn = gr.Button("🔄 Refresh", size="sm")

                gr.Markdown("### 👤 Profile")
                profile_md = gr.Markdown(_profile_markdown())

                # --- Edit profile ---
                _p = _load_profile_raw()
                _u = _p.get("user", {})
                _locs = _p.get("locations", {})
                _off = _locs.get("office", {})
                _hm = _locs.get("home", {})
                _wp = _p.get("work_pattern", {})
                _wh = _p.get("working_hours", {})
                _vb = _p.get("visit_buffer", {})

                with gr.Accordion("✏️ 編集", open=False):
                    gr.Markdown("**基本情報**")
                    name_in = gr.Textbox(label="氏名", value=_u.get("name", ""))
                    role_in = gr.Textbox(label="役職", value=_u.get("role", ""))
                    email_in = gr.Textbox(label="メール", value=_u.get("email", ""))

                    gr.Markdown("**勤務場所**")
                    office_label_in = gr.Textbox(label="オフィス名", value=_off.get("label", ""))
                    office_addr_in = gr.Textbox(label="オフィス住所", value=_off.get("address", ""))
                    home_label_in = gr.Textbox(label="自宅ラベル", value=_hm.get("label", ""))
                    home_addr_in = gr.Textbox(label="自宅住所", value=_hm.get("address", ""))

                    gr.Markdown("**曜日別勤務パターン**")
                    mon_in = gr.Dropdown(label="月曜", choices=WORK_PATTERN_CHOICES, value=_wp.get("monday", "office"))
                    tue_in = gr.Dropdown(label="火曜", choices=WORK_PATTERN_CHOICES, value=_wp.get("tuesday", "office"))
                    wed_in = gr.Dropdown(label="水曜", choices=WORK_PATTERN_CHOICES, value=_wp.get("wednesday", "office"))
                    thu_in = gr.Dropdown(label="木曜", choices=WORK_PATTERN_CHOICES, value=_wp.get("thursday", "flexible"))
                    fri_in = gr.Dropdown(label="金曜", choices=WORK_PATTERN_CHOICES, value=_wp.get("friday", "home"))
                    sat_in = gr.Dropdown(label="土曜", choices=WORK_PATTERN_CHOICES, value=_wp.get("saturday", "home"))
                    sun_in = gr.Dropdown(label="日曜", choices=WORK_PATTERN_CHOICES, value=_wp.get("sunday", "home"))

                    gr.Markdown("**営業時間 / バッファ**")
                    hours_start_in = gr.Textbox(label="始業 (HH:MM)", value=_wh.get("start", "09:00"))
                    hours_end_in = gr.Textbox(label="終業 (HH:MM)", value=_wh.get("end", "18:00"))
                    buffer_before_in = gr.Number(label="訪問前バッファ(分)", value=int(_vb.get("before", 15)), precision=0)
                    buffer_after_in = gr.Number(label="訪問後バッファ(分)", value=int(_vb.get("after", 10)), precision=0)

                    save_btn = gr.Button("💾 保存", variant="primary")
                    save_status = gr.Markdown("")

                gr.Markdown("### 🛠️ Available Tools")
                tools_md = gr.Markdown(_tools_markdown())

                def _refresh():
                    return _status_markdown(), _profile_markdown(), _tools_markdown()

                refresh_btn.click(
                    _refresh, outputs=[status_md, profile_md, tools_md]
                )

                save_btn.click(
                    _save_profile_yaml,
                    inputs=[
                        name_in, role_in, email_in,
                        office_label_in, office_addr_in,
                        home_label_in, home_addr_in,
                        mon_in, tue_in, wed_in, thu_in, fri_in, sat_in, sun_in,
                        hours_start_in, hours_end_in,
                        buffer_before_in, buffer_after_in,
                    ],
                    outputs=[save_status, profile_md],
                )

    return demo


def main():
    demo = build_demo()
    demo.queue(default_concurrency_limit=1)  # ローカルLLM共有のため直列
    demo.launch(
        server_name=os.environ.get("GRADIO_SERVER_NAME", "127.0.0.1"),
        server_port=int(os.environ.get("GRADIO_SERVER_PORT", "7860")),
        share=False,
        show_error=True,
        theme=gr.themes.Soft(primary_hue="blue"),
    )


if __name__ == "__main__":
    main()
