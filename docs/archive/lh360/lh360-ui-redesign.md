# lh360 UI 再設計 — FastAPI + React 移行

**作成日**: 2026-04-21  
**ステータス**: Phase β-1 完了（2026-04-21）  
**前提となる議論**: [lh360-plan-executor-reframing.md §追加議論 D](../concepts/lh360-plan-executor-reframing.md#追加議論-d-ui-アーキテクチャ方針)

---

## 1. 設計方針

### なぜ Gradio を捨てるか

Plan-Executor 分離（α-5 完了）により、Orchestrator がイベントストリームを返す構造が確立した。
Gradio は `EvPlanCreated` / `EvStepStart` / `EvStepEnd` を `logger.debug` で捨てており、これらを活かしたリッチな実行ビューを Gradio の制約内で作ることは限界が早い。

また、lh360 の UI の存在意義は「単なるチャット窓」ではなく、以下を提供することにある：

> **β + Plan-Executor 実行構造 + ビジネス情報のリッチビューを提供することで、ローカルアプリとしての価値を持つ。**
> 単なるチャット UI だと lh360 は「Claude の MCP server を叩くプロジェクト」に縮退する。

### LWC プレビューについての整理

設計議論では「LWC プレビュー」を UI 要素として列挙していたが、これは誤った表現だった。

- Salesforce の LWC は Apex バインディングを持ち、Salesforce プラットフォーム外では動作しない
- 既存の LWC 群（universalTableEditor, accountDashboard, etc.）はそれぞれ Salesforce UI 上での特定オペレーションのために最適化されており、lh360 に持ち込むものではない
- **lh360 UI がやるべきこと**: エージェントアウトプットを独自の React コンポーネントとしてリッチに表示する。データ取得は既存の MCP 層を使えばよく、LWC への依存は不要

「LWC プレビュー」→ **「エージェントアウトプットの React ビューワー」** に読み替える。

### UI の 2 層構造

| 層 | 主なユーザー | 内容 |
|---|---|---|
| **ビジネスビュー（主舞台）** | SAE（営業担当） | エージェントアウトプットのリッチ表示。T1〜T6 の型別カード、SOQL 結果テーブル（編集・保存付き）、関係マップなど |
| **システムビュー（サイドパネル）** | デモ観客・開発者 | Plan ステップ進行状況、Executor 種別（full/atomic/escalate）、β map、API コスト表示。開閉式 |

---

## 2. 既存 Gradio の扱い

### 廃棄するもの

`lh360/app/gradio_app.py` は β-1 完了後に削除済。削除された機能：

- `build_demo()` / `main()` — Gradio UI 構築・起動
- `_status_markdown()` / `_profile_markdown()` / `_tools_markdown()` — Markdown 文字列生成関数（JSON API に置き換え）

### そのまま移植するもの

| Gradio 内の機能 | 移植先 |
|---|---|
| `_ensure_initialized()` — MCPManager・Orchestrator・各 Executor の配線 | `lh360/app/api/startup.py` |
| `MCP_PROFILES` / `_current_specs()` — MCP プロファイル定義 | `lh360/app/api/mcp_config.py` |
| `chat_fn` のイベントループ本体 — `EvToolCallStart/Result/AssistantText/Finish` 処理 | `lh360/app/api/routes/chat.py`（SSE ストリームに変換） |
| `_load_profile_raw()` / `_save_profile_yaml()` — プロファイル IO | `lh360/app/api/routes/profile.py` |
| `_probe_mlx()` — mlx-lm 死活確認 | `lh360/app/api/routes/health.py` |
| `EXAMPLES` — サンプル発話 | React チャットコンポーネントのサジェスト定義に移動 |

### 特に重要: 捨てていたイベントを活かす

Gradio では以下を `logger.debug` で素通りさせていた：

```python
if isinstance(ev, EvPlanCreated):
    logger.debug(...)
    continue
if isinstance(ev, (EvStepStart, EvStepEnd)):
    logger.debug(...)
    continue
```

これらを SSE で React に流すことで、**Plan 実況（システムビュー）がほぼノーコストで実現できる**。

---

## 3. 新アーキテクチャ

### ディレクトリ構成

```
lh360/app/
├── api/                    # FastAPI バックエンド（新設）
│   ├── main.py             # アプリ定義・startup/shutdown
│   ├── mcp_config.py       # MCP プロファイル・specs（Gradio から移植）
│   ├── startup.py          # _ensure_initialized 相当
│   └── routes/
│       ├── chat.py         # POST /chat → SSE ストリーム
│       ├── profile.py      # GET/PUT /profile
│       └── health.py       # GET /health
└── web/                    # React フロントエンド（新設）
    ├── src/
    │   ├── App.tsx
    │   ├── components/
    │   │   ├── chat/
    │   │   │   ├── ChatPanel.tsx       # メッセージ入力・履歴
    │   │   │   └── MessageBubble.tsx   # テキスト・ツール呼び出し表示
    │   │   ├── system/
    │   │   │   ├── SystemPanel.tsx     # 開閉式サイドパネル
    │   │   │   ├── PlanTracker.tsx     # Plan ステップ進行
    │   │   │   └── StatusBar.tsx       # mlx / SF / Google 接続状態
    │   │   └── business/
    │   │       ├── OutputRenderer.tsx  # イベント型に応じてビューワーを振り分け
    │   │       ├── DataTable.tsx       # SOQL 結果テーブル（編集・保存）
    │   │       ├── RankingCard.tsx     # T1: 機会評価・ランキング
    │   │       ├── HypothesisCard.tsx  # T2: 仮説生成
    │   │       └── OutlineCard.tsx     # T3: 提案書骨格
    │   └── hooks/
    │       └── useChat.ts              # SSE 接続・イベントパース
    ├── package.json
    └── vite.config.ts
```

### 通信プロトコル

- **ユーザー発話**: `POST /chat` → レスポンスは SSE ストリーム
- **SSE イベント種別**:

```
event: plan_created    # Planner がプランを生成した
event: step_start      # ステップ開始（executor 種別・elementary ID 含む）
event: step_end        # ステップ完了
event: tool_start      # tool 呼び出し開始
event: tool_result     # tool 呼び出し結果
event: text            # アシスタントテキスト（チャンク）
event: finish          # 完了
event: error           # エラー
```

- **プロファイル**: `GET /profile` / `PUT /profile`
- **ヘルスチェック**: `GET /health`

### フロントエンド技術選定

- **Vite + React + TypeScript**: シンプルで高速なローカル専用 SPA。Next.js は不要（SSR 要件なし）
- **Tailwind CSS**: スタイリング
- **shadcn/ui**: コンポーネント基盤（Salesforce SLDS ライクな見た目を最小コストで）

---

## 4. フェーズ計画

### Phase β-1: バックエンド + チャット基盤 ✅ 完了 (2026-04-21)

1. FastAPI サーバー実装（`api/`）
2. SSE ストリーミング配線（既存 Orchestrator イベントをそのまま流す）
3. React チャットパネル + システムビュー（Plan 実況）

**完了基準**: Gradio と同等のチャット動作 ＋ Plan ステップが画面に見える状態

**実装結果**:
- チャット送受信・Plan 実況パネル・ツール呼び出し表示すべて動作確認済
- SSE `\r\n` 正規化問題を解決（sse-starlette は CRLF で送出、パーサーは LF 前提だった）
- Starlette CORSMiddleware が SSE StreamingResponse をバッファする問題を回避するため raw ASGI CORS ミドルウェアを実装
- **残存課題**: Gemma 4 の応答遅延（thinking トークン生成に数分かかる場合がある）— UI 層ではなく agent 層の問題

### Phase β-2: ビジネスビュー第 1 弾

- `DataTable.tsx`: SOQL 結果の表示・インライン編集・MCP 経由保存
- `RankingCard.tsx`: T1 アウトプット表示

### Phase β-3: ビジネスビュー拡充

- T2〜T6 対応カード
- プロファイル編集フォーム

### Phase γ: Electron ラッパ化

- `web/` の成果物を Electron で包む
- mlx-lm-server の spawn を app プロセスに統合

---

## 5. 実装で得た知見

### SSE + Starlette の落とし穴

1. **sse-starlette は CRLF (`\r\n`) で SSE イベントを送出する**。ブラウザ側 ReadableStream パーサーは `\n\n` で split する実装が多いが、`\r\n\r\n` とマッチしない。受信時に `\r\n` → `\n` の正規化が必須。
2. **Starlette の `CORSMiddleware` / `BaseHTTPMiddleware` は StreamingResponse をバッファする**。`call_next()` がレスポンス body を読み出してから CORS ヘッダーを付与するため、SSE イベントが溜まって一括送信される。回避には raw ASGI ミドルウェア（send をラップしてヘッダーだけ追加、body は素通し）を使う。
3. **Vite dev server の proxy は SSE と相性が悪い**場合がある。直接接続 (cross-origin) か proxy 経由 (same-origin) かの選択が必要。本プロジェクトでは Vite proxy (same-origin) を採用。

### Gemma 4 応答遅延

- `max_tokens=4096` でも thinking トークンに 2000-3000 使われ、非ストリーミングの `chat.completions.create()` が数分ブロックされる
- 根本対策は agent loop への `stream=True` 導入（β-2 以降で検討）
- UI 層としては SSE ping でコネクション維持されるため、タイムアウトの問題はない

---

## 6. 未決事項

- [x] Gradio 削除: β-1 完了後に削除済。pyproject.toml から依存除去、参照元を `app.api.mcp_config` に切り替え
- [ ] `DataTable` からの保存は MCP 経由か Salesforce REST 直接か（MCP 推奨）
- [ ] Electron 移行時期の判断基準（「Gradio の限界」ではなく「React の描画要件が具体化したとき」）
- [ ] agent loop の `stream=True` 対応（Gemma 4 応答遅延の根本対策）
