"""Planner ↔ Executor 間の契約データ構造。

`TaskSpec` が 1 step の実行単位。`Plan` は N-step の実行計画。
`StepResult` が Executor から Planner に返る中間結果。

Phase α-1 では TaskSpec.mode="full" のみ使用する。
atomic / escalate は α-4 以降で実装する。

設計: docs/in-progress/lh360-plan-executor-design.md §2
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Literal


TaskMode = Literal["atomic", "full", "escalate"]
StepStatus = Literal["ok", "failed", "escalate_requested"]


@dataclass
class TaskSpec:
    """Planner → Executor の 1 step 指示。

    Planner が生成し Executor が消費する。Executor は会話履歴を持たないので、
    必要な文脈は `context` / `task_description` に詰める責務が Planner 側にある。
    """

    step_id: str
    """プラン内で一意な識別子 (例: "s1")。"""

    mode: TaskMode
    """実行モード。
    - atomic: 単発 elementary 実行 (max_turns 2-3, history 無し)
    - full:   既存 AgentLoop に丸投げ (max_turns 8, history あり)
    - escalate: γ 経路 (Claude Sonnet F 型プロンプト)
    """

    task_description: str
    """Executor に見せる自然文の指示。"""

    elementary_id: str | None = None
    """β catalog の id (例 "P7.1.3")。自由タスクは None。"""

    context: dict[str, Any] = field(default_factory=dict)
    """Executor に渡す構造化文脈 (focal_account_ids 等)。"""

    available_tools: list[str] | None = None
    """Executor に見せる tool の allow list。None = 全 tools。
    Gemma 4 は同時ロード 25 tools 以上で崩壊するため atomic モードでは絞る。
    """

    success_criteria: str = ""
    """Executor の完了判定に使う自然文基準。α-4 以降で本格活用。"""

    depends_on: list[str] = field(default_factory=list)
    """先行 step_id。topological order 実行に使う。"""


@dataclass
class Plan:
    """Planner が 1 ターン内で生成する実行計画。"""

    plan_id: str
    user_intent: str
    """Planner が解釈したユーザ意図 (1-2 文の自然文)。"""

    steps: list[TaskSpec]
    synthesis_hint: str = ""
    """全 step 完了後の合成方針。Phase α-1 では未使用。"""


@dataclass
class StepResult:
    """Executor → Planner の 1 step 結果。"""

    step_id: str
    status: StepStatus
    summary: str
    """Planner に見せる要約。生データではない。"""

    workspace_refs: list[str] = field(default_factory=list)
    """大容量結果を保存した workspace 内参照 (α-5 以降)。"""

    error: str | None = None
