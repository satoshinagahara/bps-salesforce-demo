"""lh360 Planner - Plan-Executor アーキテクチャの Planner 層。

設計: docs/in-progress/lh360-plan-executor-design.md
議論: docs/concepts/lh360-plan-executor-reframing.md

Phase α-1 (現在):
- ダミー Planner: 常に 1-step full プランを返す (既存 AgentLoop への丸投げ)
- 既存挙動を壊さずに Planner 層を配線だけ通す

Phase α-3 以降:
- Claude Sonnet による本格プラン生成
- β catalog 参照
- atomic モード / γ escalation 合流
"""
from .beta_catalog import BetaCatalog, load_catalog
from .llm import PlannerLLM, PlannerLLMConfig
from .orchestrator import Orchestrator
from .plan_schema import Plan, StepResult, TaskSpec
from .semantic_layer import (
    SemanticLayer,
    WorkspaceSemanticLayer,
    load_semantic_layer,
    load_workspace_semantic_layer,
)

__all__ = [
    "Plan",
    "TaskSpec",
    "StepResult",
    "Orchestrator",
    "BetaCatalog",
    "load_catalog",
    "PlannerLLM",
    "PlannerLLMConfig",
    "SemanticLayer",
    "load_semantic_layer",
    "WorkspaceSemanticLayer",
    "load_workspace_semantic_layer",
]
