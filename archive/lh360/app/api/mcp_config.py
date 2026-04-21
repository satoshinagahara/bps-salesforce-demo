"""MCP プロファイル定義と specs 生成。

Gradio の MCP_PROFILES / _current_specs() をそのまま移植。
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path

from agent.mcp_manager import MCPServerSpec

logger = logging.getLogger("api.mcp_config")

ROOT = Path(__file__).resolve().parents[2]  # lh360/

# Gemma 4 26B A4B 4bit は同時ロード 20 tools 未満が安全圏（実測: 25 tools で tool_call 崩壊）。
MCP_PROFILES: dict[str, list[str]] = {
    "sales":   ["sf", "gw", "fetch", "time", "brave"],
    "minimal": ["sf", "fetch", "time"],
    "full":    ["sf", "gw", "fetch", "time", "fs", "memory", "brave"],
}
DEFAULT_PROFILE = "sales"


def google_creds_ok() -> bool:
    p = Path(os.environ.get(
        "GOOGLE_OAUTH_CREDENTIALS", ROOT / "config" / "tokens" / "google_credentials.json"
    ))
    return p.exists()


def sf_username() -> str | None:
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


def current_specs() -> list[MCPServerSpec]:
    profile_name = os.environ.get("AGENT_MCP_PROFILE", DEFAULT_PROFILE)
    allow = set(MCP_PROFILES.get(profile_name, MCP_PROFILES[DEFAULT_PROFILE]))
    if profile_name not in MCP_PROFILES:
        logger.warning(f"unknown AGENT_MCP_PROFILE={profile_name!r}, using {DEFAULT_PROFILE}")
        profile_name = DEFAULT_PROFILE
    logger.info(f"AGENT_MCP_PROFILE={profile_name} → {sorted(allow)}")

    specs: list[MCPServerSpec] = []

    if "sf" in allow:
        sf_user = sf_username()
        if sf_user:
            sf_project_root = str(ROOT.parent)
            specs.append(MCPServerSpec(
                name="sf",
                command="npx",
                args=[
                    "-y", "@salesforce/mcp",
                    "--orgs", sf_user,
                    "--toolsets", "core,data,orgs",
                    "--no-telemetry",
                ],
                argument_overrides={
                    "directory": sf_project_root,
                    "usernameOrAlias": sf_user,
                },
                tool_blocklist=["get_username", "resume_tool_operation"],
            ))
        else:
            logger.warning("sf-config.json not found or missing username; sf MCP disabled")

    if "gw" in allow and google_creds_ok():
        specs.append(MCPServerSpec(name="gw", module="mcp_servers.google_mcp"))

    if "fetch" in allow:
        specs.append(MCPServerSpec(name="fetch", command="uvx", args=["mcp-server-fetch"]))

    if "time" in allow:
        specs.append(MCPServerSpec(name="time", command="uvx", args=["mcp-server-time"]))

    if "brave" in allow:
        brave_key = os.environ.get("BRAVE_API_KEY")
        if brave_key:
            specs.append(MCPServerSpec(
                name="brave",
                command="npx",
                args=["-y", "@brave/brave-search-mcp-server", "--transport", "stdio"],
                env={"BRAVE_API_KEY": brave_key},
                tool_blocklist=[
                    "brave_local_search",
                    "brave_video_search",
                    "brave_image_search",
                    "brave_summarizer",
                ],
            ))
        else:
            logger.warning("BRAVE_API_KEY not set; brave MCP disabled")

    if "fs" in allow:
        workspace_path = ROOT / "workspace"
        workspace_path.mkdir(exist_ok=True)
        specs.append(MCPServerSpec(
            name="fs",
            command="npx",
            args=["-y", "@modelcontextprotocol/server-filesystem", str(workspace_path)],
        ))

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
