# lh360 Plan-Executor 再定位議論ログ

## 位置付け

Phase 3 β (ユースケースパターン分析) + γ (F クラウドオフロード設計) 完了後、β 優先度 1 の実装フェーズ入り口で浮上した本質的な論点と、それに対する方針決定の記録。

`docs/concepts/lh360-scope-reframing.md` の続編に相当する。scope-reframing が「Gemma 4 の限界に直面してスコープをどう絞るか」の議論だったのに対し、本ドキュメントは「β 成果物を実装でどう活かすか、そもそも活かせているのか」の議論。

**日付**: 2026-04-19
**参加**: 佐藤 × Claude

---

## 経緯

β 実装の着手にあたり、以下の順で論点が展開した。

1. 「P7 Salesforce MCP は公式で良いか?」→ 合意 (公式優先の方針通り)
2. 「週次レポートのプロンプト設計、具体に書きすぎは本筋ではない」→ Claude が 3 層分離 (Agent プロンプト / 動的コンテキスト / ツール層) と **B 案 (tool-rich / prompt-thin)** を提示
3. **「B って Agentforce と同じ設計思想では?」**
4. **「じゃあ β は何のためだった?」**
5. **「β はフロンティアモデルならもっと活用される取り組みだったのでは?」**
6. 方針決定: **Plan-Executor 分離** を実験的に採用

---

## 論点 1: B 設計 = Agentforce の設計思想と同じでは?

### 提案 B の構造 (Claude が当初提案したもの)

- Agent プロンプト (薄い汎用 system prompt)
- MCP tool が業務意味論を構造化して返す (例: `get_focal_account_snapshot`)
- Gemma はツール結果を自然文化するだけ

### Agentforce との比較表

| 構成要素 | Agentforce | 提案 B (lh360) |
|---|---|---|
| 汎用 LLM | GPT-4 / Claude (フロンティア) | Gemma 4 (ローカル) |
| ドメインロジック保持層 | Action (Apex/Flow/API) | MCP tool |
| 薄い system prompt | あり | あり |
| LLM の役割 | ツール結果の要約・次アクション提示 | 同じ |
| Topic / スコープ境界 | 明示 (Topic classifier) | 暗黙 (tool description で選ばれる) |

**結論**: 機能的にほぼ同一。これは設計ミスではなく、**汎用 LLM + ドメイン特化ツール**というアーキテクチャ空間における自然な収束点。LangGraph / OpenAI Agents SDK / Agentforce / MCP いずれも突き詰めると同じ絵に辿り着く。

### lh360 を差別化する要素 (scope-reframing で既出)

1. **実行基盤**: ローカル Gemma / コスト 0 / オフライン・プライバシー対応
2. **SSoT との結合度**: Agentforce は SF 内部完結 (Apex/Flow)。lh360 は SSoT を外から叩く構造 → Salesforce 以外の SSoT にも移植可能
3. **ハイブリッド (γ)**: F パターンだけクラウド Claude にオフロード ← Agentforce は単一モデル前提
4. **エージェント loop の自前実装**: retry ロジック (Phase 3 α(2))、tool 同時ロード数制御 (Gemma 4 の 25 tools 崩壊対策) などローカル小型モデル固有の制約に対応する層

**正直な自己評価**: B 単体を切り出すと Agentforce の劣化コピーに見える。lh360 の付加価値は **B + γ + ローカル実行** をセットにしたときに初めて出てくる。

---

## 論点 2: じゃあ β (ペルソナ洗い出し → A-F 分類) は何のためだった?

### 率直な答え

**β は「B という設計を発明した」わけではない**。B (tool-rich / prompt-thin) は β なしでも Agentforce 的収束点として到達可能だった。β の膨大なブレークダウンは、B 案を生み出すためには必須ではなかった。

### しかし β が実際に買ったもの

β の価値は「設計案の発明」ではなく、**実装判断を支える根拠 (evidence) と境界線 (boundary)**:

1. **B と γ の境界線 (12% F の線)**: β なしでは γ は「Gemma が失敗したらクラウドに投げる」程度の naive fallback にしかならなかった。β は 33 件の F を 6 つの型 (T1-T6) に分類し、型別プロンプト設計まで導いた
2. **ツール粒度の正解ゾーン**:
   - A 路線 (Gemma が SOQL 書く) → β で失敗頻発と判明
   - C 路線 (固定フォーマット) → β で C/D パターンの硬直リスク明示
   - B の中でもどの粒度か → β の「何が Gemma の reasoning を超えるか」の感覚値
3. **ポータビリティの根拠 (Step 4 の 4 分類)**: 「大型案件追跡型以外のペルソナが来てもツール差し替えで回る」の裏付け
4. **「うまく動く」の確度**: 「88% の elementary task は A-E パターン」という数値根拠
5. **Q2「プロンプト具体化しすぎない」判断の裏付け**: β で「A-E は構造化ツール出力で回るが、具体的フォーマット固定は C 型に該当し硬直化する」と整理

### β の真の位置付け

**設計フェーズ** ではなく **調査・地図作成 (research / mapping) フェーズ**:

```
β (map) = 「問題空間のどこに何があるか」
  ↓ 地図を使って判断する
実装 (B + γ) = 「その空間のどこに構造物を建てるか」
```

地図なしで建築はできる。ただし勘で建てることになる。β は勘を検証済みの判断に格上げした。

### 反省点

「β 相当の効果を最短時間で得るには?」と問われたら:
- Step 1-2 (persona → groups) まで: 必要
- Step 3 (elementary → A-F 分類): 全件やる必要はなかった可能性。2-3 グループでサンプリングし「Gemma で回りそう / F は無視できない量ある」が分かれば十分だった
- Step 4 (business type): γ と portability に効くので価値あり

→ 次に同種の調査をやるときは早期に着地点を想定して scope を絞る、という教訓。

---

## 論点 3: β はフロンティアモデルならもっと活用される取り組みだったのでは?

### 結論

**YES、かなり深く活用される取り組みだった可能性がある**。現状の β は Gemma 4 の能力制約に縛られて「守りの使い方」しかできていない。

### 現状 β の使われ方 (守備的)

1. **境界線として**: 「Gemma で何ができない (F)」を特定して除外
2. **ツール粒度の指針として**: Gemma を壊さないように tool 出力を構造化する方針決め

→ これらは全部「失敗を避ける」方向の使い方。β の産物 (284 elementary 分類、Step 4 business type、F 33→6 型) の**大半の意味論情報は実装に活用されていない**。

### フロンティアモデルなら可能な「攻めの使い方」

1. **網羅性の主張材料 (カバレッジ保証)**: 「284 elementary の全件をカバーする agent を構築、成功率 X% を保証」→ β がそのまま契約/SLA の前提になる
2. **Eval benchmark**: 284 elementary = ゴールデンテストセット。各 elementary に「良い出力とは」を追加定義すれば、モデルや実装を回すたびに品質測定できる
3. **Planner への入力**: Agent = Planner + Executor 構造にしたとき、β の elementary 階層はそのまま planner の「次に解くべきサブタスク」候補リストになる
4. **Business type × Tool manifest の動的切替**: Step 4 の 4 分類を起点に、ペルソナごとに tool セット・prompt を動的構成
5. **説明可能性 (traceability)**: フロンティアモデルは elementary 粒度でメタ認知可能。「今週 agent は P3 グループの elementary 14/16 件を処理しました」のようなレポート
6. **ドメイン適応の加速**: 「このペルソナ KPI から Step 1-3 を自分で生成して」と LLM に投げられる

### 皮肉な気づき: γ は既に β のフロンティア活用路

| 層 | モデル | β の使い方 |
|---|---|---|
| 88% A-E | Gemma | 守備 (境界線・粒度のみ) |
| 12% F | Claude | 攻め (型別プロンプト・意味論活用) |

**β のポテンシャルのうち、フロンティア相当の活用は 12% の部分にしか適用できていない**。残り 88% は Gemma の制約で守備的運用に留まる。

### もし最初からフロンティア前提だったら β の作り方自体が違った

- **A-F 分類は不要だったかも**: capability 分類の重要度が下がる
- **深さ優先になっていた**: 7 グループ × 40 elementary ではなく、2-3 グループ × 100+ elementary で品質基準も併記
- **Eval 項目を同時作成**: 各 elementary に「良い出力」「悪い出力」の例を並べて benchmark 化
- **Planner 入力を意識した階層**: 依存関係/順序情報を記録

### 本質的な論点

> lh360 は **ローカル LLM 前提** のプロジェクトだが、β はその前提に縛られてポテンシャルの一部しか使えていない状態で座っているのではないか?

**その通り**。γ 設計で少しマシになるが、本丸は 88% 側 (Gemma) の扱い。ここが「defensive B 実装」に落ち着く限り、β 投資の回収率は限定的。

---

## 対応選択肢 (4 案)

1. **現状維持 (B + γ)**: β は γ 側で一部活用、残りは Gemma 進化待ち
2. **Gemma の使い方を攻めに振る**: β の elementary 分類を tool description に埋め込み、「どの elementary に今いるか」を Gemma 自身に認識させる実験。失敗リスクあるが β 活用度は上がる
3. **Plan-Executor 分離で β を planner 入力に**: Planner だけフロンティアモデル (軽量用途)、Executor は Gemma の二層構造。β の elementary 階層は planner の候補リスト。ハイブリッドがさらに深まる
4. **β を成果物として独立化**: β/γ 自体を「ローカル LLM 業務適用の方法論」として価値を持たせる

---

## 決定

**案 3 (Plan-Executor 分離) を実験的に採用**。

### 選択理由 (Claude の推薦 + ユーザー合意)

- β の地図が planner 側で本当に意味論的に使われる
- γ (F クラウドオフロード) と素直に合流する構造
- 複雑度は増すが、B 単独実装と比較したときの差別化が明確になる
- 「lh360 はローカル LLM の defensive 適用ではなく、**β の地図を活かす攻めの設計**である」という主張が成立する

### 複雑度リスク

- 二層構造の調整コスト
- Planner モデル選定 (軽量 Claude / Sonnet vs Haiku)
- Executor (Gemma) への引き渡し形式 (プラン JSON? 自然文?)
- 失敗時のリカバリ (Planner 失敗 / Executor 失敗 / 境界失敗)

これらは後続の Plan-Executor 設計ドキュメントで詰める。

---

## 次のアクション (後続で設計ドキュメント化する事項)

### Plan-Executor アーキテクチャ設計 (次の設計ドキュメントで扱う)

1. **二層の責務分担**
   - Planner: ゴール分解、elementary 識別、Executor 呼び出し順序決定
   - Executor: 単一 elementary の実行 (tool 呼び出し → 結果要約)

2. **Planner LLM 選定**
   - Claude Haiku (軽量・速い・安い) が筆頭候補
   - または Gemma 自身に planning させる case (軽いタスクのみ)
   - γ の escalate_to_cloud と統一した Claude Sonnet にする選択肢も

3. **β の elementary 階層をどう planner 入力にするか**
   - 方式 A: 284 elementary を **コンパクトな YAML/JSON カタログ**にして planner system prompt に埋め込む
   - 方式 B: 階層を vector search index にして RAG で引く (フルリストは planner に渡さない)
   - 方式 C: Step 4 business type で manifest 切替、type 内のみ planner に見せる

4. **Executor 側 (Gemma) への引き渡し形式**
   - 構造化プラン JSON (elementary_id, expected_tools, success_criteria)
   - 単一 elementary 単位で 1 loop。終了したら planner に戻す
   - または plan list を順次実行して全体を executor 側で回す

5. **ハイブリッド全体像 (Plan-Executor + γ)**
   ```
   User → Planner (Claude Haiku)
           ├─ elementary 分解 (β 参照)
           ├─ each: Executor (Gemma) → tool call
           └─ F 判定時: Escalate → Claude Sonnet (γ)
   ```

6. **先行実装の順序**
   - **選択肢 1**: B (単層 Executor) を先に動かしてから Planner を追加
   - **選択肢 2**: Plan-Executor 前提で最初から設計、B を飛ばす
   - **選択肢 3** (採用): Planner 常設だが plan サイズ可変。簡単なリクエストは `plan = [1 step]` として Executor の full モードを呼び、複雑な場合は atomic モードを複数回呼ぶ。下記「追加議論 D」で決定

---

## 追加議論 A: 先行実装順序 (選択肢 3 採用)

**論点**: 「B → Plan-Executor 追加」と「最初から Plan-Executor 前提」の違いは本質的には **Executor の契約 (interface)** の違いだった。

| 観点 | 選択肢 1 (増築) | 選択肢 2 (最初から) | 選択肢 3 (常設 + 可変プラン) |
|---|---|---|---|
| Executor の責務 | フル会話完結 (既存のまま) | 単発 elementary 実行 (要リファクタ) | 2 モード持つ (full / atomic) |
| 簡単なリクエストの経路 | Planner バイパス可 | 常に Planner 経由 | 常に Planner 経由だが trivial 1-step プラン |
| B の位置付け | default パス | 概念として消える | full モードとして温存 |
| β の活用度 | 低 | 高 | 高 |
| 失敗時リスク | Planner 追加で失敗しても B は動く | Planner がコケると全部止まる | Planner が "1-step に丸投げ" で退避可 |
| 段階的実装 | 容易 | 困難 | 容易 (Planner をダミーから本物に育てられる) |

**決定**: 選択肢 3。以下の理由:

- Planner が常設なので β の活用実験目的は達成される
- Executor の既存実装 (max_turns=8 の full モード) も捨てない
- Planner が「1 step で行け」と判断すれば B と同じ経路 → B の再評価的な実験も自然に含まれる
- 段階的実装可能: 最初「Planner は常に 1 step プランを返す」ダミーで既存動作維持 → Planner を本物に育てながら atomic モードも追加

---

## 追加議論 B: 会話コンテキストの所有権

**論点**: Plan-Executor 二層で **全体の会話コンテキストは誰が持つか**。

**決定**: **Planner のみ**。Executor は会話レベルでステートレス。

### 責務分担表

| 情報種別 | 保持者 |
|---|---|
| 会話履歴 (過去ターン全部) | **Planner のみ** |
| 現ターンのユーザ発話 | Planner のみ |
| プラン (elementary 列) | Planner のみ |
| プラン実行中の中間結果 (e1 の出力を e2 に渡す等) | Planner が中継 |
| 単発 elementary のタスク仕様 | Planner が生成して Executor に渡す |
| 単発 elementary 内の tool call ループ | Executor (自己完結) |
| 各 Executor 呼び出しの結果 | Planner に返る |

### Executor が受け取るもの (例)

```json
{
  "elementary_id": "P7.1.3",
  "task_description": "注力アカウントのうち stage 滞在が長い Opp を抽出し、要約",
  "context": {
    "focal_account_ids": ["001...", "001..."],
    "lookback_days": 14,
    "previous_step_result": null
  },
  "available_tools": ["sf__query", "get_focal_account_snapshot"],
  "success_criteria": "stalled opps の一覧と、各 opp の最終活動日"
}
```

Executor は「前回ユーザは何と言った」「3 ターン前の会話」などを**一切知らない**。必要なら Planner が context スライスに詰め直して渡す。

### 選択理由

1. **Gemma の reasoning 節約**: 会話履歴を積むと context window と reasoning 負荷が膨らむ。Gemma は狭い文脈で tool 呼ぶのが得意。β の 88% A-E 成立仮説はこの前提
2. **Planner の判断材料集中**: 会話の流れ・意図変化・前回答との整合性は Planner が一元判断すべき。分散させると矛盾
3. **β 活用との整合**: elementary 識別・business type 照合には会話文脈が要る
4. **γ との一貫性**: F 型 escalation も Planner の仕事。同じオーケストレーション役

### エッジケース

- **照応表現** 「前回の Opp はどう?」→ Planner が解決し、Executor には明示 ID で渡す
- **プラン内で e1 → e2 の結果連鎖**: Planner が state machine として動き、e1 結果を読んで e2 を組み立てる
- **途中でユーザがやり直し**: 次ターンで Planner が受け、前プラン結果を参照しつつ新プラン

### 含意

- **UI 入口 = Planner**。UI は Planner の chat endpoint を叩く。Executor は UI から見えない内部モジュール
- **既存 AgentLoop は Executor 化**: 現 `lh360/agent/loop.py` はそのまま「full モード Executor」として使える。History は Planner から渡された context スライスとして受け取る
- **atomic モードの追加**: Executor に単発 elementary 実行モード追加 (max_turns 2-3)
- **Planner は新規**: `lh360/planner/` に新設。Claude Sonnet を叩く LLM ラッパー + プラン生成 prompt + state machine

---

## 追加議論 C: Planner LLM の選定 (Haiku → Sonnet)

**論点**: Planner に Haiku を当てる初期提案は reasoning 負荷を過小評価していた。

### reasoning 負荷の分析

| タスク | 難度 | Haiku で足りる? |
|---|---|---|
| 会話履歴読解・照応解決 | 中 | ぎりぎり |
| β catalog (284 elementary) から該当選定 | **高** | 疑問 |
| プラン分解 (依存関係・順序) | **高** | 疑問 |
| 中間結果読んで次 step 決定 | **高** | 疑問 |
| F 判定 (escalation すべきか) | 中 | たぶん OK |
| 最終回答の synthesis | 中 | たぶん OK |

中央 3 つが核心。そこは Sonnet クラスでないと β catalog を意味論的に使いこなせない可能性が高い。

### コスト試算 (Sonnet 4.5 単価: $3/1M in, $15/1M out)

- 入力: 会話履歴 + β catalog + 中間結果 ≈ 5-20k tokens
- 出力: プラン JSON ≈ 500-2k tokens
- 1 ターン ≈ $0.02-0.08
- 1 日 50 ターン ≈ $1-4
- 月 30 日 ≈ $30-120

**γ の F 型 offload コスト ($1-2/SAE/月) と比べると桁違い**。Planner が常設のフロンティア呼び出しになる以上、これが lh360 の主要ランニングコスト。

### 決定

**Planner = Claude Sonnet 単独でスタート**。コスト問題が顕在化したら最適化 (Haiku カスケード、プロンプト圧縮、RAG 化で catalog 注入量削減など)。

---

## 追加議論 D: UI アーキテクチャ方針

**論点**: 入口がクラウド Planner になると、ローカルアプリとしての UI の意義は何か。単なるチャット窓なら Claude Desktop や公式 SDK で十分で、lh360 固有の UI は要らなくなる。

### UI に必然性を与える唯一の道

UI 自身が「β + Plan-Executor の実行構造 + ビジネス情報のリッチビュー」を提供すれば、ローカルアプリとしての価値が出る。単なるチャット UI だと lh360 は「Claude の MCP server を叩くプロジェクト」に縮退する。

### ビジネスビュー (主舞台) と システムビュー (脇役) の分離

| 観点 | ユーザー | UI 要素 |
|---|---|---|
| **ビジネスビュー (主)** | ビジネスユーザー (SAE) | リッチダッシュボード、リレーションマップ、移動時間チャート、レポート、Excel プレビュー、LWC プレビュー |
| **システムビュー (脇)** | デモ観客・開発者 | Plan 実況、β map、コスト経済、レイヤーインジケータ |

**主舞台はビジネスビュー。システムビューは開閉可能なサイドパネル**。前回の Claude 提案はシステムビュー過剰だった。

### デリバリー形態の論点

ビジネスビューの描画要件 (HTML ダッシュボード / リレーションマップ / チャート / LWC プレビュー) は**全部ブラウザ技術 (HTML/CSS/JS) で実装される**。LWC は Web Components 仕様なのでブラウザ/webview 以外で描画不可。

→ したがって「native vs browser」ではなく「**どういうデリバリー形態でブラウザ技術を届けるか**」が真の論点。

### 4 選択肢の比較

| 選択肢 | 実体 | 評価 |
|---|---|---|
| A. Gradio 拡張 | 現状ベース、カスタム HTML 埋め込み | 限界が早い。多ペインレイアウトや LWC 統合が曲がる |
| B. 独自 Web アプリ (ブラウザアクセス) | FastAPI + Next.js/React を `localhost` で | 描画自由度 max。ただしタブで開く「Web ツール感」が出る |
| C. Electron ラッパ | B の成果物を Chromium で包む | デスクトップアプリ化、bundle 重いが描画互換性 max |
| D. Tauri ラッパ | B の成果物を OS webview で包む | 軽量だが OS ごとの webview 差異あり |
| (E. SwiftUI 等 native) | 却下: LWC/web ライブラリ資産を捨てることになる |

### 決定

**最終形 = Electron ラッパのデスクトップアプリ**。理由:

- 「lh360.app をダブルクリックで起動」の体験は、ビジネスユーザー向けツールとしての格が違う
- 複数ウィンドウ (チャットペイン / ダッシュボードペイン / マップペイン) の自然なレイアウト
- ローカル LLM 起動の裏方 (`mlx-lm-server` の spawn) を app プロセスに隠蔽できる
- デモ時の「Chrome タブ」感なく、「製品を見ている」感が出る

Tauri でも良いが、LWC と ecosystem 豊富さで Electron 推し。

### フェージング

**Phase α — プロトタイプ期 (今)**
- 現 Gradio にカスタム HTML で Plan-Executor 実況と β map を追加
- 狙い: アーキテクチャ動作検証、描画要件の具体化

**Phase β — 移行期**
- 判断ポイント: Phase α で Gradio の限界に当たる時
- FastAPI + Next.js へ移行。ブラウザアクセス状態で動作
- 狙い: リッチビューワーの要件をフル実装できる土台

**Phase γ — パッケージ化期**
- Next.js を Electron で包む
- 狙い: 「lh360.app」としての完成度、デモ/配布用

### 今すぐ Electron にする必要はない

- プロトタイプ段階では Gradio で十分
- 移行は描画要件が Gradio を超えた時
- Phase α で動作確認優先

---

## 合意事項まとめ (実装の前提)

1. **アーキテクチャ**: Plan-Executor 分離 (選択肢 3: Planner 常設・plan サイズ可変)
2. **Planner = Claude Sonnet 単独** (コスト顕在化したら最適化)
3. **Executor = Gemma 4 のまま**、既存 AgentLoop を full モードとして温存しつつ atomic モードを追加
4. **会話コンテキスト所有は Planner のみ**、Executor はステートレス
5. **UI 最終形は Electron ラッパのデスクトップアプリ** (Phase γ)、ただし移行は描画要件が具体化してから
6. **UI 主舞台はビジネスビュー (リッチビューワー)**、システムビューは脇役サイドパネル
7. **Phase α (今) は Gradio のまま** Plan-Executor 実装に集中、UI 拡張は最小限
8. **Planner-Executor-γ の全体像**:
   ```
   User → Planner (Claude Sonnet)
           ├─ 会話履歴・意図解決
           ├─ β catalog 参照 → elementary 列プラン生成
           ├─ For each elementary:
           │    ├─ A-E 判定 → Executor (Gemma, full or atomic)
           │    └─ F 判定 → γ escalation (Claude Sonnet)
           └─ 結果 synthesis
   ```

---

## 関連ドキュメント

- [lh360-scope-reframing.md](lh360-scope-reframing.md) - Phase 3 入り口の議論ログ (Gemma 限界、A〜F 抽象化)
- [../in-progress/lh360-usecase-pattern-analysis.md](../in-progress/lh360-usecase-pattern-analysis.md) - β 成果物 (284 elementary 分類)
- [../in-progress/lh360-f-pattern-cloud-offload-design.md](../in-progress/lh360-f-pattern-cloud-offload-design.md) - γ 設計 (F → T1-T6 型別)
- [../in-progress/lh360-stocktake.md](../in-progress/lh360-stocktake.md) - プロジェクト状況

---

## この議論から得た横断的な教訓

1. **実装直前に「本当にこの設計で価値が出るか」の批判的レビュー**を挟むのは有効。今回は「Agentforce 似ではないか」の一問から Plan-Executor 方針が出た
2. **設計の収束点が既存製品と同じになるのは悪くない**。問題は差別化要素を明示的に言語化できているか
3. **研究 (β) と実装の間には「地図を活かす設計」という翻訳が必要**。地図作成で満足せず、地図の活用度を実装中も問い直す
4. **フロンティアモデル前提 / ローカル前提で β の作り方は変わるべき**。次に同種調査をやるときは model 前提を先に決める
