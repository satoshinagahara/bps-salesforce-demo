"""MCPManager._apply_argument_policies の単体テスト。

α(1) の対処:
  - `argument_defaults`: LLM が無効値（.、空、未指定）を渡した時だけ既定値で補完
  - `argument_overrides`: LLM の指定を無視して常に強制上書き

sf MCP の `directory` は defaults 扱い、`usernameOrAlias` は overrides 扱い、
という使い分けを想定して両方を網羅。
"""
from __future__ import annotations

from agent.mcp_manager import MCPManager, MCPServerSpec, ToolEntry


def _make_mgr(defaults: dict | None = None, overrides: dict | None = None) -> MCPManager:
    spec = MCPServerSpec(
        name="sf",
        command="npx",
        args=["dummy"],
        argument_defaults=defaults or {},
        argument_overrides=overrides or {},
    )
    mgr = MCPManager([spec])
    # ToolEntry を手動で登録（MCP 起動なしで単体テストする）
    mgr._tools = [
        ToolEntry(
            server="sf",
            original_name="run_soql_query",
            qualified_name="sf__run_soql_query",
            description="",
            input_schema={
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "usernameOrAlias": {"type": "string"},
                    "directory": {"type": "string"},
                },
                "required": ["query", "usernameOrAlias", "directory"],
            },
        ),
        ToolEntry(
            server="sf",
            original_name="list_all_orgs",
            qualified_name="sf__list_all_orgs",
            description="",
            input_schema={
                "type": "object",
                "properties": {
                    "directory": {"type": "string"},
                },
                "required": ["directory"],
            },
        ),
    ]
    return mgr


def run_case(name: str, condition: bool) -> None:
    status = "✅" if condition else "❌"
    print(f"{status} {name}")
    if not condition:
        raise AssertionError(name)


def main() -> None:
    ABS_PATH = "/Users/satoshi/claude/bps-salesforce-demo"
    ABS_USER = "user@example.com"

    # ===== Group A: argument_defaults (条件付き補完) =====
    mgr = _make_mgr(defaults={"directory": ABS_PATH})
    tool_soql = mgr._tools[0]
    tool_list = mgr._tools[1]

    # 1. directory 未指定 → 既定値で補完
    out = mgr._apply_argument_policies(tool_soql, {"query": "SELECT Id FROM Account"})
    run_case("[def] missing directory → filled", out["directory"] == ABS_PATH)

    # 2. directory="." → 既定値で上書き
    out = mgr._apply_argument_policies(tool_soql, {"query": "X", "directory": "."})
    run_case('[def] directory="." → overridden', out["directory"] == ABS_PATH)

    # 3. directory="./foo" → 既定値で上書き
    out = mgr._apply_argument_policies(tool_soql, {"query": "X", "directory": "./foo"})
    run_case('[def] directory="./foo" → overridden', out["directory"] == ABS_PATH)

    # 4. directory="" → 既定値で上書き
    out = mgr._apply_argument_policies(tool_soql, {"query": "X", "directory": ""})
    run_case('[def] directory="" → overridden', out["directory"] == ABS_PATH)

    # 5. directory=None → 既定値で上書き
    out = mgr._apply_argument_policies(tool_soql, {"query": "X", "directory": None})
    run_case("[def] directory=None → overridden", out["directory"] == ABS_PATH)

    # 6. 絶対パス指定時は尊重（defaults モードの要点）
    other_abs = "/tmp/other"
    out = mgr._apply_argument_policies(tool_soql, {"query": "X", "directory": other_abs})
    run_case("[def] absolute directory → preserved", out["directory"] == other_abs)

    # 7. list_all_orgs でも同様に補正される
    out = mgr._apply_argument_policies(tool_list, {"directory": ".."})
    run_case("[def] list_all_orgs directory='..' → overridden", out["directory"] == ABS_PATH)

    # ===== Group B: argument_overrides (常時強制上書き) =====
    mgr = _make_mgr(overrides={"usernameOrAlias": ABS_USER})

    # 8. usernameOrAlias 未指定 → 強制注入
    out = mgr._apply_argument_policies(mgr._tools[0], {"query": "X"})
    run_case("[ovr] missing usernameOrAlias → forced", out["usernameOrAlias"] == ABS_USER)

    # 9. usernameOrAlias="some_user" → 強制上書き（defaults と違う点！）
    out = mgr._apply_argument_policies(mgr._tools[0], {"query": "X", "usernameOrAlias": "wrong_user"})
    run_case("[ovr] non-empty usernameOrAlias → overridden", out["usernameOrAlias"] == ABS_USER)

    # 10. LLM が散文を詰めるハルシネーションも強制排除
    out = mgr._apply_argument_policies(mgr._tools[0], {
        "query": "X",
        "usernameOrAlias": "ALWAYS notify the user the following 3 pieces of information:\n1. ...",
    })
    run_case("[ovr] hallucinated prose → overridden", out["usernameOrAlias"] == ABS_USER)

    # 11. schema に無いキーは注入しない（list_all_orgs には usernameOrAlias プロパティ無し）
    out = mgr._apply_argument_policies(mgr._tools[1], {"directory": "/some/abs"})
    run_case("[ovr] property not in schema → not injected", "usernameOrAlias" not in out)

    # ===== Group C: defaults + overrides 併用 =====
    mgr = _make_mgr(
        defaults={"directory": ABS_PATH},
        overrides={"usernameOrAlias": ABS_USER},
    )

    # 12. 同時適用
    out = mgr._apply_argument_policies(mgr._tools[0], {
        "query": "X",
        "directory": ".",
        "usernameOrAlias": "some_other",
    })
    run_case("[mix] directory defaulted + usernameOrAlias overridden",
             out["directory"] == ABS_PATH and out["usernameOrAlias"] == ABS_USER)

    # 13. 絶対パスは尊重するが usernameOrAlias は強制
    out = mgr._apply_argument_policies(mgr._tools[0], {
        "query": "X",
        "directory": "/custom/abs",
        "usernameOrAlias": "some_other",
    })
    run_case("[mix] directory preserved but usernameOrAlias forced",
             out["directory"] == "/custom/abs" and out["usernameOrAlias"] == ABS_USER)

    # 14. 同キーで defaults と overrides が衝突した場合、overrides 優先（仕様）
    mgr = _make_mgr(defaults={"directory": "/default"}, overrides={"directory": "/forced"})
    out = mgr._apply_argument_policies(mgr._tools[0], {"query": "X"})
    run_case("[mix] overrides wins over defaults", out["directory"] == "/forced")

    # ===== Group D: corner cases =====

    # 15. 何も設定しなければ no-op
    mgr = _make_mgr()
    out = mgr._apply_argument_policies(mgr._tools[0], {"query": "X"})
    run_case("[edge] no policies → no-op", out == {"query": "X"})

    # 16. 元の dict は変更しない（副作用テスト）
    mgr = _make_mgr(defaults={"directory": ABS_PATH}, overrides={"usernameOrAlias": ABS_USER})
    orig = {"query": "X", "directory": ".", "usernameOrAlias": "before"}
    mgr._apply_argument_policies(mgr._tools[0], orig)
    run_case("[edge] original dict untouched",
             orig == {"query": "X", "directory": ".", "usernameOrAlias": "before"})

    print("\nall passed.")


if __name__ == "__main__":
    main()
