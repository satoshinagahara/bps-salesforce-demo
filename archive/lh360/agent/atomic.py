"""Atomic Executor - 単一 elementary を絞り込んだ tool だけで実行する。

Phase α-4 で追加。Planner が `mode="atomic"` を指定した step の実行経路。

【full Executor との違い】
- max_turns が短い (既定 3)。1 elementary = 1 成果物 = 数 turn で完了する前提
- history を必ず空にする (会話履歴は Planner が所有。Executor はステートレス)
- `available_tools` による allow list で tool を絞り込む (Gemma 4 の 25 tool 崩壊閾値対策)
- system prompt は atomic 専用: 「宣言したタスクだけを即実行し、最終回答は簡潔に」

Planner が 1 elementary に必要な tool を正確に列挙できる前提で動く。
列挙不足だと Executor が詰む可能性があるため、α-4 では Planner prompt で
「必要 tool を少し広めに出す」ように誘導する。

設計: docs/in-progress/lh360-plan-executor-design.md
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import AsyncIterator

import yaml

from .loop import AgentConfig, AgentLoop, Event
from .mcp_manager import MCPManager

logger = logging.getLogger("agent.atomic")


ATOMIC_SYSTEM_PROMPT = """\
# Atomic Executor

あなたはローカル LLM エージェントで、**単一の小タスク**を、与えられた
少数のツールだけで完結させる担当です。

## 与えられるもの

- 1 つの明確なタスク記述 (自然文)
- 必要最小限のツール集合 (既に絞り込まれている)
- 構造化コンテキスト (JSON)

## 行動原則

1. **宣言したら実行**: 「確認します」「調べます」で終わらず、同ターンで tool_call を発行する。
   タスクが「取得」「一覧」「集計」「抽出」「確認」系なら、**最初の assistant message は
   必ず tool_call を含む**。テキストだけで終わるのは禁止。
2. **迷ったら tool を呼ぶ**: 推測で値を出さない。タスク記述が曖昧でも、一番もっともらしい
   クエリで一度投げて、結果を見てから整形する
3. **並列化**: 独立した問い合わせは同一ターンで並列 tool_call (依存関係がない限り 1 ターンに束ねる)
4. **最短ルート**: このモードは max_turns が短い (3〜5)。無駄な turn を使わない
5. **最終回答は事実ベースで短く**: 完了条件に合致する結果だけを返す

## 絶対禁止 (Gemma の loop 対策)

- **同じ tool を同じ引数で 2 回以上呼ばない**: 直前の tool_result を受け取ったら、その値を
  自分の assistant message で参照し、次の異なる tool を呼ぶ or 最終回答を出す
- **tool_result を無視しない**: 結果が返ってきた次のターンでは必ず進捗させる (別の tool
  を呼ぶ or 最終回答を書く)。同じ tool の再呼び出しは禁止
- **「ユーザ情報の取得」は通常 1 回で終わる**: `sf__get_username` や `time__get_current_time`
  は一度呼べば結果が確定する。重複呼び出しは即座に最終回答に切り替える合図

## タスクの進め方 (推奨パターン)

1 ターン目: 本命の tool を**本気のクエリで**呼ぶ (下のツール別ヒント参照)
2 ターン目以降: 結果が返ってきたら**追加クエリは打たずに即最終回答**。
成功した結果をそのまま整形してユーザに提示する。

> 既に現在日時や担当者情報がシステムコンテキストで提供されている場合、改めて
> `time__get_current_time` を呼ぶ必要はない。system prompt の
> 「現在日時 (JST)」「あなたが支援する担当者」節を参照せよ。

> **tool 結果に欲しいデータが含まれていれば完了**。追加クエリで情報を厚くしたい
> 誘惑に駆られても止めること (max_turns は短い)。

## ツール別の注意

### `sf__run_soql_query`
- **必ず呼ぶ**: データ取得系タスクでは推測で答えず、**最初のターンで SOQL を発行せよ**。
  「取得します」「確認します」と宣言だけして終わるのは禁止。同ターン内で tool_call を出す。
- SOQL の集計関数には制限あり。`SUM(Amount * Probability / 100)` のような**式の
  入れ子は使えない**。`SUM(Amount)` + `SUM(ExpectedRevenue)` のような単純形で書く。
- 日付フィルタは**引用符なし**で relative date literal を使うのが堅実:
  - 今日: `CloseDate = TODAY`
  - 今週: `CloseDate = THIS_WEEK`
  - 今月: `CloseDate = THIS_MONTH`
  - 今四半期: `CloseDate = THIS_QUARTER`
  - 来週相当: `CloseDate = NEXT_N_DAYS:14`（引数つきリテラル）
  - 期日超過: `ActivityDate < TODAY AND Status != 'Completed'`
- **担当者フィルタは `Owner.Email = 'xxx@example.com'`** (Owner のフィールド参照)。
  `OwnerId = 'email@...'` は不可（Id 型にメアド文字列は入らない）。
- **AND/OR 複合条件は括弧で優先順位を明示**: `(A AND B) OR (C AND D)` のように書く。
  括弧なしで `A AND B OR C AND D` と書くと SOQL が誤解釈することがある。
- **通貨: 集計 (SUM/AVG) の結果はこの org のコーポレート通貨 (USD) で返る**。
  レコードが JPY でも `SUM(Amount)` は USD 換算値になる。JPY 表示にしたい場合は
  ConvertCurrency(Amount) を使うか、通貨単位を回答内で必ず明示する
  (例: 「USD 1,200,000 相当 (JPY 約 1.8億)」)。
- **Task の polymorphic lookup は `What`/`Who`**。Task には `Opportunity.Name` のような
  直接リレーションはない。関連レコード名を取りたい場合は `What.Name` (親: Account/Opportunity/Case 等)、
  `Who.Name` (Contact/Lead) を使う。例: `SELECT Id, Subject, ActivityDate, What.Name, Who.Name FROM Task`。
- **Task の WhatId/WhoId への IN 句は使えない** (polymorphic lookup の制約)。複数 ID で絞る場合は
  `WHERE WhatId = 'id1'` を個別に実行するか、Account/Opportunity 側のレコード ID を 1 つに絞ってから
  クエリする。`WhatId IN (SELECT Id FROM ...)` のサブクエリ形式も同様に使えない。
- **Task の ORDER BY は `ActivityDate`**（単数形）。`ActivityDATES` 等のタイポに注意。
- **OpportunityContactRole に IsPrimary 列はない**。Primary Contact を取りたい場合は
  `SELECT ContactId FROM OpportunityContactRole WHERE OpportunityId=... AND Role='Decision Maker'`
  などロール名で絞るか、`SELECT Primary_Contact__c FROM Opportunity WHERE ...` (カスタム項目) を使う。
- 引数に余計な値を書かない: `directory` / `usernameOrAlias` は呼び出し層が
  自動補完するので **省略してよい** (渡しても内部で上書きされる)。

### `time__get_current_time`
- system context の「現在日時 (JST)」で足りる場合は呼ばない。

## 出力規約

- 日本語。日時は JST 前提 (ISO 8601 は `+09:00`)
- 日本の会計年度: 月 ≥ 4 → 当年度
- PII/機密は必要最小限
- 確定的な書き込み (送信・公開) は原則下書きに留め、確定はユーザ承認を得てから

## 使用可能なツール

function definitions で渡されたものだけを使うこと。一覧にないツールを呼ばない。
"""


class AtomicExecutor:
    """atomic mode 専用の Executor。

    内部で AgentLoop を再利用するが、以下だけ差し替える:
    - system_prompt: atomic 用 (宣言即実行・短ターン前提)
    - max_turns: 3 (既定)
    - history: 常に []
    - allowed_tools: TaskSpec.available_tools から決定
    """

    def __init__(
        self,
        mcp_manager: MCPManager,
        max_turns: int | None = None,
        system_prompt: str | None = None,
        base_cfg: AgentConfig | None = None,
        field_dict: dict | None = None,
    ):
        cfg = base_cfg or AgentConfig()
        # atomic 用に max_turns を上書き (env > arg > 3)
        atomic_max_turns = (
            max_turns
            if max_turns is not None
            else int(os.environ.get("AGENT_ATOMIC_MAX_TURNS", "3"))
        )
        cfg = AgentConfig(
            base_url=cfg.base_url,
            model=cfg.model,
            api_key=cfg.api_key,
            max_turns=atomic_max_turns,
            max_tokens=cfg.max_tokens,
            temperature=cfg.temperature,
            timeout_sec=cfg.timeout_sec,
            retry_temperatures=cfg.retry_temperatures,
        )
        base_prompt = system_prompt or _load_atomic_system_prompt()
        if field_dict:
            base_prompt = base_prompt + "\n\n" + _format_field_dict_section(field_dict)
        self._loop = AgentLoop(
            mcp_manager=mcp_manager,
            cfg=cfg,
            system_prompt=base_prompt,
        )

    async def run(
        self,
        task_description: str,
        context: dict | None = None,
        success_criteria: str = "",
        allowed_tools: list[str] | None = None,
    ) -> AsyncIterator[Event]:
        """単一 elementary を実行する。

        history は渡せない (atomic は常にステートレス)。
        allowed_tools=None の場合は全 tool 開放となるが、atomic モードで
        それを使うと Gemma 4 の 25 tool 崩壊閾値を踏む可能性が高いので
        Planner 側で必ず指定するのが想定。
        """
        user_message = _format_atomic_user_message(
            task_description, context or {}, success_criteria
        )
        allowed_set = set(allowed_tools) if allowed_tools else None
        async for ev in self._loop.run(
            user_message=user_message,
            history=[],
            allowed_tools=allowed_set,
        ):
            yield ev


def _format_atomic_user_message(
    task_description: str, context: dict, success_criteria: str
) -> str:
    blocks = [f"【タスク】\n{task_description.strip()}"]
    if context:
        blocks.append(
            "【コンテキスト】\n```json\n"
            + json.dumps(context, ensure_ascii=False, indent=2)
            + "\n```"
        )
    if success_criteria:
        blocks.append(f"【完了条件】\n{success_criteria.strip()}")
    return "\n\n".join(blocks)


def _load_atomic_system_prompt() -> str:
    """atomic 用 system prompt。ファイル上書き可。

    prompts/atomic_system.md が存在すればそれを優先、無ければ埋め込み文字列。
    """
    p = Path(__file__).resolve().parents[1] / "prompts" / "atomic_system.md"
    if p.exists():
        return p.read_text(encoding="utf-8")
    return ATOMIC_SYSTEM_PROMPT


_DEFAULT_FIELD_DICT_PATH = Path(__file__).resolve().parents[1] / "data" / "soql_field_dict.yaml"


def load_field_dict(path: Path | str | None = None) -> dict:
    """SOQL フィールド名辞書を読み込む。

    path 省略時は data/soql_field_dict.yaml を使う。
    ファイルが存在しない場合は空 dict を返す（辞書なしで動くフォールバック）。
    """
    target = Path(path) if path else _DEFAULT_FIELD_DICT_PATH
    if not target.exists():
        logger.warning(f"[field_dict] not found: {target} — Executor runs without field dict")
        return {}
    try:
        data = yaml.safe_load(target.read_text(encoding="utf-8")) or {}
        logger.info(
            f"[field_dict] loaded {target.name} "
            f"v={data.get('version','?')} "
            f"objects={len(data.get('objects', []))}"
        )
        return data
    except Exception as e:
        logger.warning(f"[field_dict] failed to load {target}: {e}")
        return {}


def _format_field_dict_section(field_dict: dict) -> str:
    """field_dict を Executor の system prompt に注入するテキストに変換する。

    分量を最小限に抑えるため、correct_fields / wrong_fields / soql_recipes のみ抽出する。
    """
    objects = field_dict.get("objects", [])
    general_rules = field_dict.get("soql_general_rules", [])
    if not objects and not general_rules:
        return ""

    lines = ["## カスタムオブジェクト SOQL リファレンス",
             "",
             "以下はこの org 固有のカスタムオブジェクトの**正確なフィールド名**と",
             "**SOQL パターン**。SOQL を書く際は必ずこのリファレンスに従うこと。",
             ""]

    for obj in objects:
        api_name = obj.get("api_name", "")
        label = obj.get("label", "")
        lines.append(f"### {api_name}（{label}）")

        correct = obj.get("correct_fields", [])
        if correct:
            lines.append("**正しいフィールド名:**")
            for f in correct:
                note = f"  # {f['note']}" if f.get("note") else ""
                lines.append(f"- `{f['name']}` ({f.get('type', '')}){note}")

        wrong = obj.get("wrong_fields", [])
        if wrong:
            lines.append("**使ってはいけないフィールド名（存在しない）:**")
            for f in wrong:
                correct_name = f.get("correct", "")
                note = f.get("note", "")
                hint = f" → 正しくは `{correct_name}`" if correct_name else f" # {note}" if note else ""
                lines.append(f"- ~~`{f['name']}`~~{hint}")

        recipes = obj.get("soql_recipes", {})
        if recipes:
            lines.append("**SOQL パターン:**")
            for key, sql in recipes.items():
                lines.append(f"```sql\n-- {key}\n{sql.strip()}\n```")

        lines.append("")

    if general_rules:
        lines.append("### 共通ルール")
        for rule in general_rules:
            lines.append(f"- {rule}")

    return "\n".join(lines)
