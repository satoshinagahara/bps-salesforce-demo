# lh360 Plan-Executor β-シナリオ検証レポート (α-4)

**日時**: 2026-04-20 深夜〜早朝 (JST)
**環境**:
- Planner: Claude Sonnet 4.6 (prompt cache 有効 / invalidation 対策済)
- Executor: Gemma 4 26B A4B 4bit (mlx-lm OpenAI-compat, `http://127.0.0.1:8080`)
- Scenario runner: `lh360/agent/scenario.py` (新規作成 — Gradio代替の CLI テストハーネス)
- MCP profile: sales (`sf` + `gw` + `fetch` + `time`) = 9 tools
- Atomic max_turns: 7 / Full max_turns: 15 / **max_tokens: 4096 (今回追加)**

## 経緯

UI 側での手動検証が疲弊してきたため、CLI からシナリオを流せる
`agent/scenario.py` を新設。ユーザ判断で 5 シナリオを自動実行し、
改修が必要なら自律的に修正する方針で実施した。

## シナリオ結果サマリ

| # | シナリオ | 初回 | 最終 | 主な所見 |
|---|---------|------|------|---------|
| S1 | 参照チェーン (Account→Primary Contact) | ✅ | ✅ | OCR(OpportunityContactRole) データ不在に対しフォールバック (Contact.AccountId) で解決 |
| S2 | 多段合成 (今月勝った Opp の金額・商品内訳・次アクション) | ✅ | ✅ | 3-step plan + synthesis が期待通り機能 |
| S3 | 時系列トレンド (CALENDAR_MONTH 集計) | ✅ | ✅ | 通貨が USD (corp currency) で返ることを確認 |
| S4 | クロスツール (SOQL → Gmail 下書き) | ✅ | ✅ | sf + gw プロファイルで問題なし |
| S5 | 曖昧要求 (「来週何を優先すべき？」) | ❌ x3 | ✅ | **重大バグ発見 → 修正**。下記参照 |

## 🔴 S5 で発見した重大バグ: `finish_reason='length'` 空応答

### 症状

曖昧要求「来週何を優先すべきかな？」に対し、Planner が 3 つの atomic step
(来週クローズ候補 / 期日タスク / stale Opp) に分解するのは正しく動いた。
しかし **全 step が 1 turn で空応答を返し、synthesis が「結果を取得できず」
で締めくくる** という失敗が 3 回連続して再現した。

初回は「mlx-lm が落ちたのか？」と疑ったが、`curl /v1/models` で正常応答、
[tool_call_format_broken] の警告も一切無し。

### 原因切り分け

`agent/loop.py` に下記の診断ログを追加して raw response を観測:

```python
if not tool_calls:
    if turn == 0:
        logger.warning(
            f"[no_tool_on_first_turn] finish_reason={choice.finish_reason!r} "
            f"content_len={len(msg.content or '')} "
            f"content_preview={(msg.content or '')[:400]!r}"
        )
```

結果:

```
[no_tool_on_first_turn] finish_reason='length' content_len=0 content_preview=''
```

→ **Gemma 4 の thinking phase が mlx-lm のデフォルト max_tokens (~500) を
使い切り、可視 output ゼロで停止していた**。system prompt + tool schema が
長めのケース (特に atomic prompt に多くのヒントを追記した後) で顕在化する。

### 修正

`AgentConfig.max_tokens` フィールドを新設し、`chat.completions.create(…, max_tokens=self.cfg.max_tokens)` で常時渡すようにした。

```python
# agent/loop.py
max_tokens: int = field(
    default_factory=lambda: int(os.environ.get("AGENT_MAX_TOKENS", "4096"))
)
```

- 2048 で試したところ s1/s2 は復旧したが s3 (stale Opp 判定) でまだ length 切り
- 4096 に引き上げて **S5 全 step が復旧**

`AtomicExecutor.__init__` でも `max_tokens` を親 cfg からコピーするよう修正済。

## ✨ 副次的に適用した atomic prompt 改善

S5 デバッグ過程で観測した Gemma のミスをシステム化するため、
`lh360/agent/atomic.py` の `ATOMIC_SYSTEM_PROMPT` に以下を追記:

1. **行動原則 #1 を強化** — 「取得/一覧/集計/抽出/確認系タスクでは最初の
   assistant message に必ず tool_call を含む」と明示
2. **SOQL hints 追加**
   - **通貨**: `SUM(Amount)` は corp currency (USD) で返る。この org は
     corp=USD、JPY rate=150 なので回答時に通貨単位を必ず明示
   - **Task polymorphic lookup**: `Opportunity.Name` リレーションは無い。
     `What.Name` / `Who.Name` を使う
   - **OpportunityContactRole に `IsPrimary` 列は存在しない** (取得したい場合は
     Role 名絞り込み or Opp.Primary_Contact__c カスタム項目)
   - **Owner.Email** を `OwnerId='email'` と書かない (型不整合)
   - **AND/OR 複合条件は括弧で優先順位を明示**
   - **来週相当**: `CloseDate = NEXT_N_DAYS:14` リテラルを使う

## 環境整備ログ

- `config/user_profile.yaml` の email を実アドレス
  (satoshi.nagahara@gmail.com) に合わせた
- SF User.Email も同アドレスへ更新 (verification flow 完了)。Owner.Email
  絞り込みと Gmail 下書き宛先がリンクする
- `lh360/.env`: `AGENT_ATOMIC_MAX_TURNS=7` (初期 5 → 7 に増)
- (今回) `AGENT_MAX_TOKENS=4096` を .env に追加可能 (デフォルト既に 4096)
- `lh360/agent/scenario.py` 新規作成 — Gradio 不要で CLI からシナリオを流せる

## 🟡 未対応 / フォロー事項 (明日確認いただけると助かります)

1. **ANTHROPIC_API_KEY rotation** — α-4 完了後に実施予定
   ([docs/in-progress/lh360-api-key-rotation.md](lh360-api-key-rotation.md))
2. **OCR レコード不在** — S1 シナリオで Primary Contact を引くとき
   OpportunityContactRole が空。デモ映え観点でシード投入を検討
3. **`[no_tool_on_first_turn]` WARNING ログ** — 診断用に入れたが、
   有用なので残してあります (不要なら削除可)
4. **S5 で s2 が Task relationship エラー** を出す回があった
   (`Opportunity.Name` を `What.Name` に直す必要)。atomic prompt にヒント
   追加済だが、最終的に Gemma が学習してくれるかは要観察
5. **synthesis の日付解釈** — 一部の run で Sonnet が "来週 = 2/24-2/28"
   と誤出力 (現在 4/20)。synthesis system prompt にも現在日時を注入すべきか検討

## 変更ファイル一覧

- `lh360/agent/scenario.py` (新規) — CLI テストハーネス
- `lh360/agent/loop.py`
  - `AgentConfig.max_tokens` 追加 (default 4096)
  - `_generate_with_retry` に `max_tokens` 引数伝播
  - `[no_tool_on_first_turn]` 診断ログ追加
- `lh360/agent/atomic.py`
  - `AtomicExecutor.__init__` で `max_tokens` を親から copy
  - `ATOMIC_SYSTEM_PROMPT` に SOQL ヒント追記 (通貨 / Task / OCR /
    AND/OR 括弧 / NEXT_N_DAYS / 行動原則強化)
- `lh360/config/user_profile.yaml` — email 実アドレスに統一

## 所感 (明日の議論の叩き台)

Gemma 4 26B A4B + Plan-Executor 構成は、**曖昧要求を Sonnet が適切に分解し、
絞り込んだ tool で Gemma が実行する**というアーキテクチャの効用が確認できた。
単体 Gemma では絶対に成立しない質問「来週何を優先すべき？」にも、
Plan-Executor 分離で妥当な回答を返せている。

発見した max_tokens 問題は Gemma 4 の **thinking phase** が長い (4bit 量子で
推論に多くトークンを使う) のが根本原因。2048 では足りず 4096 が現実的最小線。
実運用でさらに長い複合タスクを入れる場合は 8192 も検討余地あり。

atomic prompt のヒントは β-catalog レベルに押し上げる候補があるかも
(Planner 側で elementary 単位に「ガードレール」を埋め込む設計)。これは
α-5 以降で検討したい。
