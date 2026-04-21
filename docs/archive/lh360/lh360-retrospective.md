# LH360 (Local Headless 360) プロジェクト顛末書

**作成日**: 2026-04-21
**ステータス**: 終了（後継プロジェクトへ移行）

---

## 1. プロジェクトの目的

**Local Headless 360** — ローカル LLM（Gemma 4 26B）と Salesforce 公式 MCP を中心とした MCP ツール群を組み合わせ、SAE（Senior Account Executive）の業務を自律的に支援するエージェントを構築する取り組み。

- **Local**: ローカル LLM（Gemma 4）で推論を完結させ、クラウド API 依存を最小化
- **Headless 360**: Salesforce が公式 MCP（`@salesforce/mcp`）で打ち出した「UI なしでも Salesforce を使える」というコンセプト

---

## 2. 時系列

| 時期 | フェーズ | 内容 |
|---|---|---|
| Phase 1 | 基盤構築 | Gemma 4 + 自作 Salesforce MCP → AgentLoop（mlx-lm 推論 + MCP tool 呼び出し） |
| Phase 2 | 汎用化 | Anthropic 公式 MCP 群（fetch, time, memory, filesystem）+ Playwright 導入。デモ特化コードを除去し��用エージェント基盤化 |
| Phase 3 α | スコープ再定義 | Gemma 4 の限界に直面。ユースケースを A〜F パターンに分類し、F パターン（能力超過）をクラウドにオフロードする設計 |
| Phase 3 β | カタログ構築 | SAE 業務を 284 elementary に分解した β カタログ作成。7 グループ × ��ターン分類 |
| Phase 3 γ | Cloud Offload 設計 | F ���ターン 6 型（T1〜T6）の分類と EscalateExecutor 設計 |
| α-1〜α-3 | Plan-Executor 実装 | Claude Sonnet を Planner、Gemma 4 を Executor とするハイブリッド構成。Orchestrator 配線 |
| α-4 | AtomicExecutor | Gemma 4 が複雑な multi-step を壊すため、1 tool 1 call に縮退させる AtomicExecutor を追加 |
| α-5 | EscalateExecutor | F パターン全 6 型対応。Claude Sonnet への escalation 配線完了 |
| Phase A/B | 外部統合 | セマンティックレイヤー（SF + Google Workspace）、Brave Search MCP 追加 |
| β-1 | UI 移行 | Gradio → FastAPI + React。SSE ストリーミング、Plan 実況パネル |

---

## 3. 技術的成果

### 3.1 アーキテクチャ上の発見

- **Plan-Executor 分離**: フロンティアモデル（Claude Sonnet）で計画し、ローカル LLM（Gemma 4）で実行する 2 層構成。ローカル LLM の推論能力不足を Planner で補う設計パターン
- **セマンティックレイヤー**: describe API では取れないカスタムオブジェクトの業務意味・運用ポリシー・SOQL のハマりどころを YAML で構造化し、Planner に注入。**この知見は LLM の能力に依存せず、どのモデルでも精度を上げる汎用的なアプローチ**
- **β カタログ**: SAE 業務の体系的分類（284 elementary, 7 グループ）��エージェントの能力範囲を可視化する手法
- **MCP プロファイル**: Gemma 4 の tool 数制限（25 以上で崩壊）に対する用途別プロファイル分離

### 3.2 Gemma 4 の限界として確認されたこと

- **同時 tool 数**: 25 tools 以上で tool_call フォーマット崩壊。20 未満が安全圏
- **max_tokens 未指定問題**: thinking phase でトークン予算が枯渇し空応答になる。4096 以上の明示指��が必須
- **推論速度**: thinking トークン生成に数分かかる場合がある。ストリーミング未対応だとブロッキング
- **複雑な推論**: multi-hop の tool chain を自力で組み立てる能力が不足。AtomicExecutor への縮退が頻発
- **結論**: ローカル LLM でのエージェント構築は現時点では実用に耐えない。フロンティアモデルとの性能差���大きすぎる

### 3.3 SSE + Starlette の実装知見

- sse-starlette は CRLF で送出。ブラウザ側パーサは LF 正規化が必須
- Starlette CORSMiddleware は StreamingResponse をバッファする。raw ASGI ミドルウェアで回避
- Vite dev server の proxy は SSE と相性が悪い場合がある（Accept-Encoding 除去で対処）

---

## 4. 成果物の棚卸し

### 4.1 後継プロジェクトに持ち出すもの

| 成果物 | 持ち出し形態 |
|---|---|
| `sf_semantic_layer.yaml` | 内容を新プロジェクトの CLAUDE.md に統合 |
| `gw_semantic_layer.yaml` | 同上 |
| React UI の骨格（App, ChatPanel, MessageBubble のスタ��ル） | コード移植 |
| `beta_catalog.yaml` | 参考資料として（Planner 注入は不要、Claude が自力で判断できるため） |

### 4.2 このプロジェクトに残すもの

| 成果物 | 理由 |
|---|---|
| MCP 関連クレデンシャル（sf-config.json, Google OAuth tokens, .env） | 複数プロジェクトから参照する共有資産 |
| Salesforce メタデータ（LWC, Apex, フロー等） | Salesforce デモ環境の管理は継続 |
| docs/ 配下のドキュメント群 | 設計判断の記録として保存 |

### 4.3 役目を終えたもの（後継では不要）

| 成果物 | 不要の理由 |
|---|---|
| `lh360/planner/` (Orchestrator, PlannerLLM) | Claude Code が計画・実行を一体で担う |
| `lh360/agent/` (AgentLoop, AtomicExecutor, EscalateExecutor) | 同上 |
| `lh360/agent/mcp_manager.py` | Claude Code の MCP 管理に置き換わる |
| MCP プロファイル管理 (`mcp_config.py`) | Claude Code は tool 数制限なし |
| `lh360/app/api/` (FastAPI バックエンド) | MCP server + WebSocket に置き換わる |
| `lh360/app/gradio_app.py` | β-1 完了後に削除済 |

---

## 5. 終了の判断理由

### 5.1 直接的な理由

Gemma 4 の推論能力とパフォーマンスが実用水準に達しな���った。Plan-Executor 分離、AtomicExecutor、セマンティックレイヤー等の補償設計で能力不足を埋めようとしたが、以下が解消できなかった：

- 応答速度が数分単位で実用に耐えない
- 複雑なタスクでの tool_call 崩壊が頻発
- 結局 Claude Sonnet���Planner + EscalateExecutor）が処理の大部分を担い、Gemma 4 の貢���が限定的

### 5.2 構造的な理由

Gemma 4 の弱さを補うために構築した全てのレイヤー（Plan-Executor 分離、AtomicExecutor、EscalateExecutor、MCP プロファイル制限）は、Claude をフル活用する構成では不要になる。**ローカル LLM 前提のアーキテクチャが、クラウドモデル利用時にはそのまま負債に転化する。**

### 5.3 後継の方向性

- **エージェント本体**: Claude Code / Claude Desktop（既存の MCP オーケストレーション能力をそのまま活用）
- **UI 層**: Claude Code に MCP server として接続する薄い React UI。Excel ライクな一括編集ビュー等、ターミナルでは不便な操作を担う
- **ドメイン知識**: セマンティックレイヤーの内容を CLAUDE.md に統合（YAML ファイルとしての外部管理は不要）

---

## 6. 学びの総括

1. **ローカル LLM エージェントは時期尚早** — 2026 年 4 月時点の Gemma 4 26B クラスでは、MCP ツール群を使ったエージェント構築は���用化が難しい。ただしモデルの進化速度を考えると、1-2 年後には状況が変わる可能性がある
2. **セマンティックレイヤーは LLM 非依存の資産** — カスタムデータモデルの業務意味を構造化する手法は、どの LLM を使っても精度を上げる。Gemma 4 のためだけのものではなかった
3. **Plan-Executor 分離は「弱い Executor」がいる場合にのみ意味がある** — Executor がフロンティアモデルなら、分離は単なるオーバーヘッド
4. **「補う」より「置き換える」方が速い** — 弱い LLM を精巧な補償設計で支えるより、強い LLM にそのまま任せる方が、コード量・保守コスト・実行速度の全てで優れる
5. **β カタログの価値は「実装ガイド」ではなく「業務理解」** — 284 elementary の分類作業自体が SAE ���務の深い理解につながった。この知見はセマンティックレイヤーに凝縮されている
