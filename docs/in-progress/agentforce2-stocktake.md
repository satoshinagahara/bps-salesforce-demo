# Agentforce 2.0 — 棚卸し台帳（Phase 2 再設計用）

**作成日**: 2026-04-18
**目的**: Phase 1 で自作した MCP / プロンプト / Agent Loop を「Salesforce SSoT 中核は残す / それ以外は汎用化」という方針で棚卸し。

---

## 1. 方針の再確認

- **軸1**: Salesforce は SSoT の中核。ここは自作継続を基本としつつ、公式 [`@salesforce/mcp`](https://github.com/salesforcecli/mcp) 採用の是非は別途判断
- **軸2**: それ以外（Web、時刻、ファイル、記憶、ブラウザ、認証済み外部サービス等）は**タスク非依存な汎用エージェント基盤**として組む
- **軸3**: デモシナリオ特化のロジック・語彙・手続き書はプロンプト / MCP から除去。シナリオごとの振る舞いは「その時点で必要な MCP を追加する」という運用で実現

### 汎用基盤の最小構成（リサーチ結果より）

Anthropic reference 7 本 + Microsoft Playwright を核とし、ローカル LLM に必要なものだけ入れる:

| 層 | 採用 MCP | 提供元 |
|---|---|---|
| Filesystem | `filesystem` | Anthropic 公式 |
| HTTP 取得 | `fetch` | Anthropic 公式 |
| 時刻 | `time` | Anthropic 公式 |
| 記憶 | `memory` | Anthropic 公式 |
| Git | `git` | Anthropic 公式 |
| 思考補助 | `sequential-thinking` | Anthropic 公式（14B 以上で効果） |
| ブラウザ | `playwright` | Microsoft 公式 |
| Web 検索 | SearXNG / Tavily / Exa | 要選定 |

---

## 2. 現物件インベントリ

### 2.1 自作 MCP サーバ

#### `agentforce2/mcp_servers/salesforce_mcp.py`

| ツール | 区分 | 判定 | 理由 |
|---|---|---|---|
| `soql_query` | Core | **残す** | SSoT アクセスの中核。LLM にとって最も汎用的な道具 |
| `sobject_describe` | Core | **残す** | メタデータ参照。汎用 |
| `sobject_read` | Core | **残す** | 単一レコード読み取り。汎用 |
| `sobject_create` | Core | **残す** | 書き込み。汎用 |
| `sobject_update` | Core | **残す** | 書き込み。汎用 |
| `sobject_delete` | Core | **残す** | 書き込み。汎用 |
| `get_priority_opportunities` | Composite | **除去** | 「シナリオA（訪問調整）向け商談優先度」というタスク特化。汎用エージェントなら `soql_query` で LLM が組み立てる |
| `get_contact_visit_info` | Composite | **除去** | 同上。訪問前提のバンドル |
| `create_visit_event` | Composite | **除去** | 同上。`sobject_create` で汎用代替可 |
| `_jp_fiscal_quarter_range` | 内部 | **除去** | Composite に付随するヘルパ。日本会計年度のロジックは LLM 側の判断に委ねる（必要なら system prompt に "日本会計年度" の簡潔な定義だけ残す） |

**結論**: `salesforce_mcp.py` は Core 6 ツールのみに圧縮。Composite 3 つは削除。

**未判断**: 公式 `@salesforce/mcp` に全乗り換えするか → 別トピックとして後日判断（`sf` CLI 認証との親和性が高く魅力的だが、SSoT 中核は自前で握りたいという選択も妥当）

---

#### `agentforce2/mcp_servers/google_mcp.py`

| ツール | 区分 | 判定 | 理由 |
|---|---|---|---|
| `calendar_list_events` | Calendar | **汎用 MCP に置換** | community/公式の Google Workspace MCP に寄せる（OAuth 更新追随コストが重い） |
| `calendar_check_availability` | Calendar | **汎用 MCP に置換 or LLM 合成** | 複数スロット busy 判定。`calendar_list_events` + LLM で同等のことは可能 |
| `calendar_create_event` | Calendar | **汎用 MCP に置換** | 同上 |
| `gmail_create_draft` | Gmail | **汎用 MCP に置換** | 同上 |
| `maps_travel_time` | Maps | **除去**（汎用手段で代替） | Fetch + Playwright + Geocoding 等で代替可能。「地図 API 呼び出し」をエージェント固有能力として抱える必要は薄い |
| `get_user_profile` | Profile | **別レイヤーへ移設** | これは MCP ツールではなく「エージェントのユーザ設定」という性質。system prompt への動的注入（既に実装済み）が本来の置き場。MCP ツールとしての露出は廃止 |

**結論**: `google_mcp.py` は全面廃止または大幅縮小。代替 MCP 選定が Phase 3 以降のタスク（各候補の tool 数・schema 品質・ローカル LLM 動作を個別評価してから決める）。

**判断が必要な論点**:
- `taylorwilsdon/google_workspace_mcp` を採用するか、Claude Desktop connector 型を見るか
- `maps_travel_time` は本当に汎用エージェントに必要か？ （Playwright で Google Maps Web を叩く + Fetch で十分なのでは）

---

#### `agentforce2/mcp_servers/web_mcp.py`

| ツール | 区分 | 判定 | 理由 |
|---|---|---|---|
| `web_fetch` | Generic | **廃止** | Anthropic 公式 `fetch` の完全下位互換。保守負債 |
| `transit_search` | Domain | **要再検討** | Yahoo 路線情報スクレイピング。汎用エージェント基盤としては不要。タスクが発生した時点で (a) Playwright で Yahoo 路線情報 Web を叩く (b) 駅すぱあと公式 MCP 導入 (c) 自作継続 から選ぶ |

**結論**: `web_mcp.py` は一旦**ファイルごと廃止**。`fetch` MCP 導入で `web_fetch` を置換、`transit_search` は必要になったタスクの文脈で再評価。

---

### 2.2 プロンプト

#### `agentforce2/prompts/system_scenario_a.md`

**現状**: シナリオA（訪問調整）に極度に特化。以下を含む:

- "シナリオAの基本フロー" 7ステップの手続き書
- "スケジュール計算の厳密ルール"（移動→到着→バッファ→アポ開始の式）
- 最寄り駅対応表（丸の内→東京、等）
- 禁止語彙（「約90分と想定」等）
- 良い例／悪い例の出力フォーマット
- composite tool (`get_priority_opportunities` 等) への依存

**判定**: 全面改訂。汎用エージェントの**原則**レベルに戻す（目安 20〜30 行）。シナリオ非依存の内容だけ残す。

**残す内容（候補）**:
- 役割（Salesforce SSoT を中核としたアシスタント）
- 書き込み系ツールは markdown 表示で済ませず必ず呼ぶ（汎用的アンチパターン対策）
- 日本語応答、JST デフォルト
- 事実ベース、推測禁止
- 並列 tool_call 可能なら使う

**削除する内容**:
- シナリオ A の 7 ステップフロー
- スケジュール計算式
- 最寄り駅対応表
- 「約〇分は禁止」等の特化ルール
- 良い／悪い出力例の具体文

---

### 2.3 Agent Loop / 動的コンテキスト

#### `agentforce2/agent/loop.py::_build_dynamic_context()`

**現状**: 毎ターン、現在時刻（JST）+ `user_profile.yaml` の全内容（氏名/役職/メール/オフィス住所/自宅住所/曜日別勤務パターン/営業時間/訪問バッファ/推論ルール）を system prompt に注入。

**判定**:
- **現在時刻注入**: 残す（ただし汎用 `time` MCP を入れれば LLM が能動的に取得可能になるので、重複は整理対象）
- **ユーザプロファイル注入**: 役割が曖昧。本来は「営業訪問シナリオ用のユーザ設定」であり、シナリオ非依存の汎用基盤には不要。Phase 3 で訪問調整タスクが来た時に専用の追加プロンプト or 専用 MCP で入れ直す想定
- **推論ルール**（"訪問日の出発地は work_pattern に基づく" 等）: 完全にシナリオA特化。除去

**結論**: `_build_dynamic_context()` は「現在時刻の1〜2行」まで削減、もしくは `time` MCP 導入後に完全撤去。

---

### 2.4 Gradio UI (`agentforce2/app/gradio_app.py`)

**現状**: プロファイル編集 UI、MCP spec 登録 (`_current_specs()`)、チャット履歴整形

**判定**:
- **プロファイル編集 UI**: 汎用基盤としては不要（訪問シナリオ固有の設定項目だらけ）。ただし**デモ用途**として残しておくのは許容（削除まではしない）。Phase 3 でタスク起点で見直す
- **`_current_specs()`**: 汎用 MCP への差し替えに合わせて書き換え
- **チャット UI 本体**: 汎用的な MCP 実行ビジュアライザーとして再利用可。残す

---

### 2.5 ユーザ設定ファイル

#### `agentforce2/config/user_profile.yaml`

**現状**: 氏名、勤務場所、曜日別勤務パターン、営業時間、訪問前後バッファ

**判定**: シナリオA（訪問）特化データ。汎用基盤には不要だが、ファイル自体は残して構わない（害はない）。動的プロンプト注入から外すことで基盤からは切り離す。

---

## 3. アクション一覧（優先順）

### P1: プロンプトのスリム化

- `prompts/system_scenario_a.md` → `prompts/system_base.md` にリネーム相当の全面書き換え
- 20〜30 行の汎用原則プロンプトへ
- 手続き書・対応表・禁止語彙を全削除

### P2: 自作 MCP の縮小

- `salesforce_mcp.py`: Composite 3 ツール + `_jp_fiscal_quarter_range` を削除
- `web_mcp.py`: ファイルごと削除
- `google_mcp.py`: 汎用 MCP への置換方針が固まるまで一旦 disable（`_current_specs()` から外す）

### P3: Agent Loop のクリーンアップ

- `_build_dynamic_context()` のユーザプロファイル注入を削除
- 現在時刻のみ残す（もしくは `time` MCP に移行後に撤去）

### P4: 汎用 MCP の導入

- `fetch` (Anthropic) を `_current_specs()` に追加
- `filesystem` (Anthropic) を追加
- `time` (Anthropic) を追加
- `memory` (Anthropic) を追加
- `playwright` (Microsoft) は必要性が見えてから（ブラウザを開くタスクが出たら）

### P5: Salesforce 公式 MCP の比較検討

- `@salesforce/mcp` を手元でセットアップし、自作 Core 6 ツールと比較
- 「SSoT 中核を自前で握る vs 公式に寄せる」の判断材料を作る

### P6: 素の Gemma 4 能力検証

- シナリオ特化ルールを全て剥がした状態で、汎用タスク（「Account を10件読んで要約」「ドキュメント書いて」「Web から情報取ってきて」等）を投げて素の振る舞いを観察

---

## 4. 判断待ち論点（あなたに委ねるもの）

1. **Salesforce 公式 MCP `@salesforce/mcp` に乗り換えるか** — SSoT 中核を自前で握る方針だと自作継続が妥当だが、公式の 60+ ツール（`run_soql_query` / `run_apex_test` / `deploy_metadata` / Code Analyzer）を捨てるのは惜しい
2. **Google Workspace MCP の選定** — `taylorwilsdon/google_workspace_mcp` 一本化か、Claude Desktop connector 型か、そもそも汎用基盤に入れず個別タスク時に追加か
3. **`user_profile.yaml` の扱い** — 残す（将来のタスクで再利用）／削除（シナリオA遺物）
4. **プロンプト再設計の進め方** — ゼロから書き直し vs 今のファイルから削る方式

## 5. 判断結果（2026-04-18）

1. **Salesforce**: 公式 `@salesforce/mcp` に乗り換える → 自作 `salesforce_mcp.py` は**ファイルごと廃止**
2. **Google Workspace**: Gmail / GCal レベルなら汎用的と考え、現自作 `google_mcp.py` を**基盤層として残す**（ただし `get_user_profile` ツールの扱いと Composite 除去は別途判断）
3. **user_profile.yaml**: 残す（将来のシナリオタスクで再利用）。ただし Agent Loop の動的コンテキスト注入からは外す
4. **プロンプト**: **ゼロから書き直し**。`system_scenario_a.md` は参考として残すが、新規に `system_base.md` を作る

### 採用する基本方針（全プロジェクト横断ルール）

> **MCP を選ぶときは、まず公式ベンダー提供のものがあるかを確認し、あれば優先採用する**。
> 判断順: ① Anthropic reference → ② サービス提供元公式 → ③ 公式 Registry の healthy → ④ 自作

Google Workspace MCP についても、今は自作を残すが**将来的には公式・準公式への移行を念頭に置く**（Google からの公式 MCP が出揃った段階で再評価）。

---

## 6. 実走観察ログ（Phase 2 #1〜#5 完了後、2026-04-18 夜）

Phase 2 #1〜#5 を適用した状態（公式 @salesforce/mcp 採用 / 自作 Salesforce・web MCP 全廃止 / `system_base.md` を徹底汎用化 / 動的コンテキストは「現在日時 + SSoT identity + 担当者 identity」の3ブロックに縮小）で、素の Gemma 4 26B A4B 4bit の挙動を観察。

### テスト手順（3連投）

1. 「今四半期の優先商談トップ5を教えてください」
2. 「東日本FG 全店舗設備保全クラウド導入の担当者に来週訪問アポを取ろうと思います。私の日程を確認して適切な時間を提案して」
3. 「そもそもこの商談の先方の担当者ってだれでしょう？」

### 観察結果

**良い挙動（汎用化が機能している）**

- 最初のターンで `sf__run_soql_query` を自発的に叩き、金額 DESC で top 5 を抽出。SSoT を base プロンプトから直書きしなくても、動的コンテキストの `## このセッションの SSoT: Salesforce` だけで SSoT 行動は維持された
- 抽出ロジックを応答に先回りで添える・「他基準もあり得る」と注記する節度
- ツールで取れた事実のみで応答し、推測値を作らない
- 担当者 identity（北杜 堅志郎 / satoshi.nagahara@gmail.com）は動的コンテキスト注入で署名・メール本文に正しく反映された
- 勤務場所・勤務パターン等を動的コンテキストから削除した効果は明確で、「相手方の業務時間（例：10:00〜17:00）を想定」という一般論での候補提示に退化した（#5 の意図通り）

**素の Gemma 4 26B の限界として観察された失敗パターン**

- **多段 SOQL の連鎖推論ができない**: 「担当者は誰」と聞かれて `Opportunity → AccountId → Account → Contacts` のような多段 SOQL を自発的に組み立てられない
- **詰まると "宣言して止まる" に戻る**: 「システム上の制約によりエラー」と架空のエラーを述べ（ハルシネーション）、「私の方で試行します」と予告して tool_call を発行せずターンを終える
- **人間に情報を求めに行く**: Salesforce 内にある情報を "お手元の資料や記憶で" とユーザに問い合わせる。これは base プロンプトの行動原則 1（宣言したら実行する）・2（分からないなら調べる）の二重違反だが、**素の Gemma 4 の能力境界**として再現性高く観察される

**書き込み系の境界事例（前セッション）**

- `gmail_create_draft` で `to` が空のまま呼び出し、Gmail API が 400 "Invalid To header" を返却
- LLM は失敗を隠さず、本文テキストを応答に貼った上で「宛先を教えてもらえれば改めて下書きを生成し直します」と未完了を明示申告
- ハルシネーションでの成功偽装はしていない。失敗時フォールバック挙動は想定以上に正直
- **根本原因は書き込み前に宛先（Contact.Email）を SOQL で引かないこと**。これは「書き込み前に必須パラメータを SSoT から引く」という汎用原則を行動原則 3 に組み込み済み（反映後もこの癖は完全には抜けない）

### 結論

- base プロンプトの徹底汎用化（SSoT を抽象概念化、ドメイン固有語を全排除）と動的コンテキストでの identity 注入方式は機能する
- ただし **Gemma 4 26B の素の agentic 能力には明確な上限**があり、多段参照を要する場面で「宣言して止まる」パターンが再現する
- Phase 2 #6（filesystem / time / memory MCP 追加）で tool 数が増える状況で、この傾向がどう変化するかを再評価する
- Phase 2 #7 の最終検証時に、本観察ログをベースラインとして比較する

---

## 7. tool 数閾値の実測（2026-04-18 深夜）

Phase 2 #6 で追加した MCP 群を全部入れた状態で test driver（`tests/test_agent_driver.py`、Gradio を介さず直接 AgentLoop を叩く）を使い、段階的に閾値を測定。

### 手順

`AGENT_MCP_SUBSET` 環境変数で MCP を絞り、同一プロンプト「今四半期の優先商談トップ5を教えてください。」で tool_call の生成可否を観察。

### 結果

| 構成 | MCP | tool 数 | 結果 |
|---|---|---|---|
| 1 | sf + gw + fetch + time | 11 | ✅ 正常（8 turns で完結、top 5 を抽出） |
| 2 | sf + gw + fetch + time + memory | 20 | ✅ tool_call は出る（ただし `list_all_orgs` の結果を活用しきれず途中で諦める reasoning 劣化） |
| 3 | sf + gw + fetch + time + fs | 25 | ❌ **`finish_reason=tool_calls` だが `msg.tool_calls=None`**（tool_call format 崩壊） |
| 4 | 全部（+memory +fs） | 34 | ❌ 同上（format 崩壊、turn 1 で空返却） |

### 判断

- **20 tools までは tool_calling フォーマット自体は健全**。reasoning 品質は多段参照が絡むと劣化する（構成2 で観察）
- **25 tools で既に崩壊**。fs（14 tools、スキーマが長い）の追加がトリガー。単純な tool 数だけでなく合計スキーマトークン量が効いている可能性が高い
- Gemma 4 26B A4B 4bit を使う前提では、**同時ロードする MCP は 20 tools 未満を運用上の上限**とする
- 用途ごとに MCP を切り替える「動的ロード」か、プロンプト側で MCP プロファイル（sales / support / devops 等）を切る運用に寄せる

### 実装メモ

- tool_call format 崩壊時の挙動: `loop.py` に `finish_reason=tool_calls` かつ `msg.tool_calls=None` のログを追加済み（検知可能）
- test driver (`tests/test_agent_driver.py`) は `AGENT_MCP_SUBSET="sf,gw,..."` で subset を切れる。Gradio UI を経由しないので Claude 側から直接観測可能
- `gradio_app.py` 側は `AGENT_MCP_PROFILE` で起動時プロファイル選択（`sales` デフォルト / `minimal` / `full`）。動的ロードは Phase 3 以降

---

## 8. Phase 2 #7: 素の Gemma 4 能力検証（sales profile 11 tools での再実走、2026-04-18 深夜）

Section 6 と同じ 3 連投プロンプトを `sales` プロファイル（sf + gw + fetch + time = 11 tools）で再実走し、Section 6 のベースライン（34 tools 構成時）と比較。

### 結果サマリ

| ターン | 実走結果 | Section 6 比較 |
|---|---|---|
| 1 「今四半期の優先商談トップ5」 | ❌ `finish_reason=tool_calls`（turn 1 で tool_call format 崩壊、空返却） | Section 6 実走では成功していた |
| 2 「訪問アポ取りたい、日程提案して」 | ✅ 12 turns 使って Opportunity 検索 → カレンダー確認 → 候補 3 件提示まで完遂 | Section 6 より**良い**（前回は仮押さえ作成まで行けたが失敗リカバリ多かった） |
| 3 「そもそも先方の担当者は？」 | ❌ Salesforce MCP の `directory` 引数 validation で詰まって同じ invalid を 10 回繰り返し、最後は「少々お待ちください」で終了 | Section 6 と同じ「宣言して止まる」限界が再現 |

### 重要な観察

**1. 11 tools でも稀に tool_call format が崩壊する**

Section 7 の閾値測定では 11 tools は安定していたが、今回 TURN 1 で崩壊。`finish_reason=tool_calls` / `msg.tool_calls=None` が turn 1 で発生。サーバ状態、セッション内の微妙なコンテキスト差、あるいは mlx-lm 側のサンプリングゆらぎで、11 tools でも**非ゼロの確率で崩壊する**と判断すべき。

→ 運用では「20 tools 未満で必ず動く」ではなく「20 tools 以上では安定して壊れる」と捉える。再試行ロジック（自動リトライ / turn 制限解除時の再問合せ）の追加も検討の余地あり。

**2. 対話ターンを重ねると reasoning は機能する**

TURN 2 のように前ターンの文脈（商談名「東日本FG …」）を受け継ぎ、get_username → run_soql_query → calendar_list_events と多段を組み立てる能力は維持されている。

**3. Salesforce MCP の API 引数スキーマは Gemma 4 にとって難しい**

`directory` が「絶対パス必須・path traversal 不可」という制約を、Gemma 4 は説明なしに学習できない。エラー文言から制約を読み取って修正する能力が弱く、`.` / `/home/user/workspace` / `.` のループにはまる。

→ 運用上の緩和策: システムプロンプトか動的コンテキストに「Salesforce MCP の `directory` 引数には絶対パス `/Users/satoshi/claude/bps-salesforce-demo/agentforce2` を渡す」と明記する（汎用性は落ちるがデプロイ固有の補正として許容）。

### Phase 2 クローズ判定

**Phase 2 のゴール（シナリオ非依存な汎用基盤への移行）は達成**:
- 自作 Salesforce/web MCP は全廃、公式へ移行
- base プロンプトは SSoT 中立の抽象表現のみ
- 動的コンテキストは時刻 + SSoT identity + user identity の 3 ブロック
- MCP プロファイル切替で tool 数問題を回避

**Phase 3 以降に繰り越す論点**:
- Salesforce MCP の `directory` 絶対パス問題への対処（プロンプト注入 vs. wrapper 層）
- tool_call 崩壊時の自動リトライ
- モデルアップグレード時の閾値再計測（Gemma 4.5 / Qwen3 など）
- プロファイル動的切替の実需が出た段階での設計
