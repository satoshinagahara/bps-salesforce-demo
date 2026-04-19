# Local Headless 360 — F パターン Cloud Offload 設計

**作成日**: 2026-04-19
**位置付け**: Phase 3 γ。β（[lh360-usecase-pattern-analysis.md](./lh360-usecase-pattern-analysis.md)）で identified した F 33 件（全 elementary の 12%）を、ローカル Gemma 4 で扱わず cloud LLM（Claude / GPT）にオフロードする設計。
**前提となる議論**: [lh360-scope-reframing.md §5](../concepts/lh360-scope-reframing.md#5-補論-f-パターンをクラウド-llm-にオフロードする設計は成立するか) で概念レベルは合意済。本ドキュメントはそれを具体設計に落とす。

---

## 1. 設計の前提と目標

### γ で決めるべきこと

1. **F 33 件の型共通化**: 33 件ばらばらに扱うのは非効率。何種類の「型」に収束するか
2. **オフロードのトリガ**: いつ・どうやって F を識別するか
3. **context 引き継ぎ**: ローカル → クラウドに何を渡すか（privacy 境界含む）
4. **戻り方**: クラウドの出力をローカルに戻すか / UI 直出しか
5. **テンプレ化**: 型ごとの cloud prompt template
6. **実装段階**: γ の成果物は設計（紙）。実装着手は別判断

### 設計原則

- **LLM 自己判断に頼らない** (§5): F 識別は orchestrator 層の heuristics + 型分類
- **α(1)/α(2) と同列の wrapper 層として配置**: AgentLoop を改造せず、MCP 層の外側で接続
- **privacy-first**: credentials / internal prompts は絶対にクラウドに送らない
- **cost-conscious**: 1 SAE あたり月 Claude API 数十 call 程度の規模想定

---

## 2. F 33 件の型分類

β の全 F elementary を「何を判断しているか」で分類したところ、**6 型に収束**した。

### F-T1: 機会評価 / 優先順位付け（7 件）

複数候補 → 評価軸で採点 → ランキング。

| ID | elementary | 所属 |
|---|---|---|
| e1-4-c | 未カバー領域の機会度評価 | P1 |
| e2-8-d | 課題優先順位付け示唆 | P2 |
| e2-9-d | qualification Go/No-Go 判定 | P2 |
| e6-1-d | アップセル仮説の優先順位付け | P6 |
| e6-5-c | 派生ターゲット候補の優先順位 | P6 |
| e6-9-a | 事例化候補スクリーニング | P6 |
| e4-6-c | 勝因・敗因の仮説抽出（評価軸含む） | P4 |

**共通構造**: `candidates[] + criteria[]` → `ranked_list + score_with_rationale`

### F-T2: 仮説生成 / 根本原因推定（6 件）

観察データ → 原因候補 → 検証可能な仮説リスト。

| ID | elementary | 所属 |
|---|---|---|
| e1-2-c | ボトルネック・改善機会の仮説抽出 | P1 |
| e2-8-c | 課題ツリー骨格ドラフト | P2 |
| e3-11-d | 他事例適用可能性判定 | P3 |
| e4-6-d | 次 Opp への示唆抽出 | P4 |
| e5-3-c | トラブル初動対応案（原因仮説含む） | P5 |
| e6-4-a | 新サービス適用可否評価 | P6 |

**共通構造**: `observations[] + domain_context` → `hypotheses[] with testability + priority`

### F-T3: 骨格設計 / スケルトン生成（5 件）

最終成果物の階層構造を「目次 + セクション要点」で出す。

| ID | elementary | 所属 |
|---|---|---|
| e1-5-a | アプローチプラン骨格ドラフト | P1 |
| e3-1-d | ソリューションポートフォリオ設計 | P3 |
| e3-8-a | 提案書骨格ドラフト | P3 |
| e4-2-d | 交渉シナリオドラフト（段階的譲歩設計） | P4 |
| e6-7-b | MSA 条項素案ドラフト | P6 |

**共通構造**: `goal + constraints + references[]` → `outline{section, purpose, key_points[]}`

### F-T4: 絶対マッチング評価（4 件）

候補 × 条件 → 適合度評価 → 選定。

| ID | elementary | 所属 |
|---|---|---|
| e3-1-c | ソリューションマッチング評価 | P3 |
| e3-3-b | スキーム絞り込み | P3 |
| e3-3-e | スキーム推奨書ドラフト | P3 |
| e6-2-b | クロスセルマッチング | P6 |

**共通構造**: `candidates × requirements` → `match_matrix + recommendation`

F-T1 との違い: T1 はランキング（相対）、T4 は閾値適合（絶対）。

### F-T5: リスク / 整合性評価（5 件）

条項/条件セット → リスク/非整合箇所 → 対策案。

| ID | elementary | 所属 |
|---|---|---|
| e1-6-b | 主要リスク・対策の棚卸し | P1 |
| e3-5-e | 工程短縮代替案 | P3 |
| e3-9-c | RFP 整合性チェック | P3 |
| e4-4-c | 契約書リスク条項一次評価 | P4 |
| e6-7-d | MSA 条項リスク評価 | P6 |

**共通構造**: `target_document + standard_ref` → `risks[] with severity + mitigation`

### F-T6: 構造マッピング / ポジショニング（3 件）

多次元軸 → 各要素の座標 → 構造化出力。

| ID | elementary | 所属 |
|---|---|---|
| e1-7-d | 競合 vs 自社ポジションマッピング | P1 |
| e4-2-b | 顧客側交渉カードの想定 | P4 |
| e4-2-c | 自社側譲歩カードの整理 | P4 |

**共通構造**: `entities[] + dimensions[]` → `positioned_map + interpretation`

### その他（3 件、型に収まらない）

| ID | elementary | 所属 | 備考 |
|---|---|---|---|
| e1-3-d | 意思決定関係性ドラフト | P1 | パワーチャート由来、T3 骨格設計に寄せるのが妥当 |
| e3-8-a が F-T3 に含まれているので重複確認必要 | — | — | — |

→ 再集計: 33 件のうち **32 件が 6 型にカバーされる**（97%）。残 1 件は個別対応。

### 型分布まとめ

| F type | 件数 | 割合 | 設計難度 |
|---|---|---|---|
| F-T1 機会評価 | 7 | 22% | 中（スコア基準の明示が難所） |
| F-T2 仮説生成 | 6 | 19% | 高（出力の検証性確保） |
| F-T3 骨格設計 | 5 | 16% | 低（テンプレ化しやすい） |
| F-T4 マッチング | 4 | 13% | 低（構造が単純） |
| F-T5 リスク評価 | 5 | 16% | 中（専門知識が必要） |
| F-T6 マッピング | 3 | 9% | 中（軸の設計が手間） |
| 個別 | 1-3 | 5% | — |

**優先実装の順**: T3 + T4（低難度、13 件 = 41%）→ T1（高頻度、7 件 = 22%）→ 残りを後追い。

---

## 3. オフロード・アーキテクチャ

### 3 層構成（α(1)/α(2) と同列の wrapper）

```
┌────────────────────────────────────────────┐
│ UI / user                                   │
│           ↓                                  │
│ ┌─────────────────────────────────────────┐ │
│ │ Pre-router (軽量分類器)                 │ │
│ │   - user message を F type に試分類    │ │
│ │   - F 疑いなら escalate tool を enable  │ │
│ └─────────────────────────────────────────┘ │
│           ↓                                  │
│ ┌─────────────────────────────────────────┐ │
│ │ Gemma 4 AgentLoop                       │ │
│ │   MCP tools (A-E 対象)                  │ │
│ │   + escalate_to_cloud(f_type, context) │ │
│ └─────────────────────────────────────────┘ │
│    ↓                                         │
│ ┌─ A-E: ローカル完遂                         │
│ └─ F: escalate tool 呼出し                   │
│        ↓                                     │
│   ┌───────────────────────────────────┐     │
│   │ Offload Wrapper                   │     │
│   │  - type-specific template fill    │     │
│   │  - context masking                │     │
│   │  - Anthropic API 呼び出し          │     │
│   └───────────────────────────────────┘     │
│        ↓                                     │
│   ┌───────────────────────────────────┐     │
│   │ Return Router                      │     │
│   │  - assist: Gemma に戻し、次 turn │     │
│   │  - overflow: UI 直出力            │     │
│   └───────────────────────────────────┘     │
└────────────────────────────────────────────┘
```

### 3 種の F 検知方式と γ での採用

§5 で提示された 3 方式のうち、γ では以下を組合わせる:

| 方式 | γ 採用 | 理由 |
|---|---|---|
| **1. 事前ルーティング** | ◎ 主軸 | 軽量分類器（ルールベース + 埋め込み類似度）でタスク入力時に F type を予測 |
| **2. 事後検知** | △ Phase 4 | α(2) retry が尽きた時点を trigger にできる。γ では後続接続ポイントだけ用意 |
| **3. 明示的 escalate tool** | ○ 副軸 | Gemma の "諦める" バイアスが追い風になる稀なケース。pre-router が enable した時だけ露出 |

**採用組合せ**: (1) → Gemma プロンプトに F type ヒントを注入 + (3) escalate tool を追加 → Gemma が (3) を呼ぶ or 事前判定で直送。

### 事前ルータの実装方針

**Stage 1（ルールベース）**:
- 正規表現 + キーワードマッチでタスクを 6 型にざっくり分類
- 例: 「優先順位」「トップ N」「ランク」 → T1 / 「骨格」「目次」「スケルトン」「素案」 → T3
- precision より recall 優先（取りこぼしを escalate tool で補う）

**Stage 2（埋め込み類似度）**: Stage 1 の精度が足りない場合、各 F type の代表例とのコサイン類似度で判定（E5-small 等の小型モデル、ローカル CPU で動く）。

**Stage 3（別モデル）**: Phase 4 以降、distilBERT クラスを fine-tune する選択肢。β の 33 件が訓練データとして使える。

γ のスコープは **Stage 1 まで**（設計の凍結に必要十分）。

### escalate_to_cloud tool の schema

```json
{
  "name": "escalate_to_cloud",
  "description": "複雑な判断・評価・構造設計が必要なタスクを cloud LLM に委譲する。ローカル LLM で扱えない F パターンタスク専用。",
  "input_schema": {
    "type": "object",
    "properties": {
      "f_type": {
        "type": "string",
        "enum": ["T1", "T2", "T3", "T4", "T5", "T6"],
        "description": "F 型: T1=機会評価, T2=仮説生成, T3=骨格設計, T4=マッチング, T5=リスク評価, T6=マッピング"
      },
      "task_description": {
        "type": "string",
        "description": "タスク内容を 1-2 文で要約"
      },
      "context_data": {
        "type": "object",
        "description": "判断に必要なデータ（候補一覧・評価軸・制約等）。事前に SSoT から収集済みのものを渡す"
      },
      "return_mode": {
        "type": "string",
        "enum": ["assist", "overflow"],
        "description": "assist=結果を Gemma に戻して次 turn で draft を作る, overflow=cloud の出力をそのまま UI に表示"
      }
    },
    "required": ["f_type", "task_description", "context_data", "return_mode"]
  }
}
```

重要な設計: **context_data は Gemma が埋める**。Gemma は「何を cloud に渡すべきか」は判断できる（データ収集 = A-E の得意領域）。判断できないのは「どう評価するか」だけ。

---

## 4. Context 引き継ぎと privacy 境界

### 送る / 送らない境界

| データ | 送信 | 備考 |
|---|---|---|
| user message（現在ターン） | ○ | |
| SSoT 読み取り結果（匿名化後） | ○ | Account 名・金額・人名は masking オプション |
| F type テンプレ | ○ | 静的、固定文言 |
| 現ターンの tool 実行結果 | ○ | escalate 前に Gemma が収集した結果 |
| 直近 N turns の history | △ | default N=2、overflow 時のみ拡張 |
| 全 history | × | プライバシーと cost 両面で過大 |
| system prompt（base） | × | デプロイ固有情報を含む可能性、送らない |
| dynamic context（identity） | × | 担当者名・メール等、masking が必要 |
| MCP tool schemas | × | 送る必要がない（cloud は tool を呼ばない） |
| credentials / tokens | × | 絶対 |

### Masking 設計

`context_data` 中の以下パターンを送信前に置換:

| 原データ | Masking 後 | 備考 |
|---|---|---|
| Account.Name | `[ACCOUNT_A]`, `[ACCOUNT_B]` | アカウントが複数出る時は連番 |
| 固有の会社名（外部データ） | `[COMPANY_X]` | 競合名などは原則送らない |
| 個人名（Contact.Name 等） | `[CONTACT_1]` | 役職は残す |
| 金額 | `[AMOUNT: ~100M JPY order]` | オーダー（桁数）は残す |
| メールアドレス・電話 | 削除 | |
| 日付 | そのまま | F 判断に必要 |
| 商品型番・仕様 | そのまま | 判断材料として必要 |

Masking は **on/off toggle** にし、default on。ユーザが「masking なしで正確に評価してほしい」と明示した時だけ off にする（デモ用途 + 同意あり前提）。

### 返り値の扱い

cloud から返った rationale / ranking に masked 表記が入っていたら、ローカル側で **逆変換してから UI に表示**する必要がある。

→ `MaskingContext` オブジェクト（送信時の mapping を保持）を escalate 呼出しごとに 1 個作り、送信時に apply、返却時に reverse apply。

---

## 5. F type ごとの Cloud Prompt テンプレ

全 6 型の template を設計する。いずれも Anthropic API (Claude Sonnet) を default target とし、system + user の 2 段構成。

### 共通部分（全 template で共有）

**system**:
```
You are assisting a senior account executive (SAE) at a B2B manufacturing company dealing with energy-scale products. Your role is to provide structured analytical output for decisions the SAE will make.

Constraints:
- Use only provided data. Do not fabricate facts about accounts, people, or competitors.
- Output must be structured (JSON or clearly delineated sections).
- Be concise. Rationale should be 1-2 sentences per item.
- If data is insufficient, say so explicitly rather than guessing.

The SAE will review and act on your output, so clarity and traceability matter more than polish.
```

### F-T1 機会評価 template

**user**:
```
Task: {task_description}

Candidates to evaluate ({N} items):
{candidates}

Evaluation criteria:
{criteria}

Context snapshot:
{context_data}

Output format (JSON):
{
  "ranked": [
    {"id": "...", "score": 1-10, "rationale": "1 sentence"},
    ...
  ],
  "top_3_actions": [
    {"id": "...", "next_action": "concrete action the SAE can take this week"}
  ],
  "insufficient_data": ["field names if any criterion couldn't be assessed"]
}
```

### F-T2 仮説生成 template

**user**:
```
Task: {task_description}

Observations:
{observations}

Domain context:
{context_data}

Output format (JSON):
{
  "hypotheses": [
    {
      "statement": "...",
      "supporting_evidence": ["..."],
      "testability": "how to verify — SOQL / interview / document / observation",
      "priority": "high | medium | low"
    }
  ],
  "top_hypothesis_reason": "why this is the most likely root cause"
}
```

### F-T3 骨格設計 template

**user**:
```
Task: {task_description}

Goal: {goal}
Audience: {audience}
Constraints: {constraints}

Reference materials (existing related work):
{references}

Output format (JSON):
{
  "outline": [
    {
      "section": "...",
      "purpose": "what this section achieves",
      "key_points": ["bullet 1", "bullet 2", ...],
      "data_needed": ["what SSoT / external data to pull"]
    }
  ],
  "recommended_order": "1→2→3→... with reasoning",
  "risks": ["potential gaps in the outline"]
}
```

### F-T4 マッチング template

**user**:
```
Task: {task_description}

Candidates:
{candidates}

Requirements:
{requirements}

Output format (JSON):
{
  "match_matrix": [
    {"candidate": "...", "requirement": "...", "fit": "full | partial | none", "note": "..."}
  ],
  "recommended_candidate": "... (id)",
  "recommendation_rationale": "1-2 sentences",
  "partial_fit_mitigations": ["for partial fits, how to close the gap"]
}
```

### F-T5 リスク評価 template

**user**:
```
Task: {task_description}

Target document / condition set:
{target}

Standard reference (what "normal" looks like):
{standard}

Output format (JSON):
{
  "risks": [
    {
      "location": "section / clause reference",
      "deviation": "how it deviates from standard",
      "severity": "critical | moderate | low",
      "mitigation": "concrete suggestion"
    }
  ],
  "overall_recommendation": "proceed | request changes | escalate to legal",
  "showstoppers": ["items that must be resolved before moving forward"]
}
```

### F-T6 マッピング template

**user**:
```
Task: {task_description}

Entities to position:
{entities}

Dimensions (axes):
{dimensions}

Output format (JSON):
{
  "positioned": [
    {"entity": "...", "coordinates": {"<dim_1>": "value", "<dim_2>": "value", ...}, "note": "..."}
  ],
  "clusters": [
    {"members": ["..."], "characterization": "what they have in common"}
  ],
  "strategic_implication": "2-3 sentences on what this map suggests"
}
```

### テンプレ版管理

- 各 template は `lh360/prompts/f_types/{T1,T2,...}.md` に保存
- version は git 管理
- フィールド差し替え失敗の防御として **jinja2 style** で unresolved `{var}` があれば呼出しを reject

---

## 6. 戻り方: assist vs overflow

escalate 時に指定する `return_mode` で挙動が分岐する。

### assist モード

クラウドの構造化出力を **Gemma の next turn に tool_result として渡す**。Gemma はそれを読んで最終応答（例: draft メール、draft 提案）を組む。

適性: **F-T1 / F-T4 / F-T5 / F-T6**（評価結果を使ってローカルで draft を書く流れ）

フロー:
```
1. user: "アップセル優先順位を教えて"
2. Gemma: SFDC から設備・契約・実績を収集（A-E 複数 hop）
3. Gemma: escalate_to_cloud(f_type=T1, context_data=..., return_mode=assist)
4. Wrapper: Claude API call → ranked list を受信
5. Wrapper: tool_result として Gemma に返却
6. Gemma: ranked list の top 3 について「次アクション」を含む draft を生成
7. user に返却
```

### overflow モード

クラウドの生出力を **そのまま UI に表示**（Gemma に戻さない）。

適性: **F-T2 / F-T3**（仮説生成・骨格設計は cloud 出力そのものが成果物）

フロー:
```
1. user: "提案書の骨格を作って"
2. Gemma: 関連素材（過去案件・顧客課題）を SFDC から収集
3. Gemma: escalate_to_cloud(f_type=T3, context_data=..., return_mode=overflow)
4. Wrapper: Claude API call → outline を受信
5. Wrapper: UI に直接表示（Gemma は次 turn を生成せずセッション終了）
6. user が outline を見て「ここを深掘り」などの新 turn を開始
```

**なぜ分けるか**: Gemma に全部戻すと、長い構造化出力を改変してしまう（要約や脱落）。assist 型は評価結果（短い）なら戻せるが、overflow 型（長い）は戻すと劣化する。

---

## 7. 失敗モードとフォールバック

| 失敗 | 検知 | 対処 |
|---|---|---|
| Claude API timeout | `anthropic.APITimeoutError` | 1 回リトライ、失敗したら「クラウド接続失敗、ローカルで粗案を作ります」と Gemma にフォールバック指示 |
| Claude が JSON パース不能 | `json.JSONDecodeError` | response を text として扱い、Gemma に「構造化できなかった」とだけ伝える |
| API quota 超過 | `anthropic.RateLimitError` | 当該ターンは諦めて UI に「本日の cloud offload 上限に達しました」と表示 |
| masking 逆変換失敗 | masked token が応答に残る | warning ログ + 原文表示（user に「一部マスクされたまま」と注記） |
| pre-router の誤分類 | posteriori に Gemma が escalate しない | tool unused でも UI 側で問題なし（偽陰性は許容、偽陽性が損害大） |

---

## 8. コスト見積もり（概算）

Claude Sonnet 4.5 の料金（2026-04 時点）で試算:

| 項目 | 値 |
|---|---|
| 1 escalate 平均 input tokens | ~3000 (context + template) |
| 1 escalate 平均 output tokens | ~800 (structured JSON) |
| 1 call 平均コスト | ~$0.02 (USD) |
| 1 SAE の想定月間 F 発生数 | 40-60 回 |
| 1 SAE 月間コスト | **~$1-2 USD** |
| チーム 20 SAE | **~$20-40 USD/month** |

→ コストは実質問題にならない規模。ローカル推論にかける電力と比較しても桁違いに安い。

ただし F 以外（A-E）で誤って escalate される偽陽性は倍率効きに注意。pre-router の precision が 0.7 を切ると cost が跳ねる。

---

## 9. 実装段階の提案

### Stage 1: Minimum Viable Offload（γ の紙設計を直接実装）

- F-T1 + F-T3 + F-T4 の 3 型のみ（16 件 = 48% カバー）
- pre-router はルールベース（20-30 行の regex）
- escalate_to_cloud tool を MCP としては出さず、**AgentLoop 側の内部実装**として追加（`_handle_escalate` メソッド）
- masking は初期は "strict off"（全部送る）、後から on 化
- Anthropic API key は `.env` 経由

**実装ポイント**: α(1)/α(2) と同じく **AgentLoop を改造せず wrapper として被せる**。`escalate_to_cloud` は疑似 MCP tool として tools list に追加、実行は AgentLoop 内で intercept。

### Stage 2: Full Coverage

- F-T2 / F-T5 / F-T6 追加（全 32 件 / 97% カバー）
- masking layer 実装
- assist vs overflow の return_mode 両対応

### Stage 3: Closed Loop

- α(2) retry exhausted → escalate 自動 fallback（事後検知）
- pre-router を埋め込み類似度に upgrade（Stage 2 までの escalate ログを訓練データに）
- コスト上限・quota ガード

### 実装着手の判断

**γ 時点では着手しない**。理由:

1. β で示した実装優先度は **P7+P5 → P3 → P2+P4 → P1+P6** で、F を含むのは P1/P6 など最後のグループ
2. 先に A-E で稼働実績を作り、**実際に F が何回発生するかを計測**してから Stage 1 の必要性を再評価
3. 現状 Gemma 4 のままでも user は F を「紙にメモして別途 Claude Desktop に貼る」で運用可能（workaround あり）

→ γ は **紙設計で凍結し、実装は β 優先度の A-E 実装が一巡してから再評価**。その時点で F 発生頻度のログがあれば、Stage 1 着手の根拠が揃う。

---

## 10. 設計上の残留論点

| 論点 | 現状の考え | 先送り可否 |
|---|---|---|
| pre-router の precision 担保 | Stage 1 はルールベース、偽陽性は許容範囲 | Stage 2 で再検討 |
| masking の誤消し（domain term が固有名扱いになる） | 実装時に NER の辞書チューニングが必要 | 実装時 |
| assist 戻り時の Gemma 改変 | structured output を context に戻すと Gemma が要約する傾向。構造保持の指示を強める | 実装時 |
| context window（3000 tok 前後）が F-T3 で不足 | 骨格設計は参考素材が多いと token 膨張。選別ロジック必要 | Stage 2 |
| escalation abuse（user が意図的に F 化） | quota guard で制御 | Stage 3 |
| モデル格上げ時の γ 廃止 | Qwen3 32B dense 等で F が解ける可能性。廃止 or 併用の判断基準を決めておく | モデル到来時 |

---

## 11. γ のクローズ判定と次への引き継ぎ

### γ 完了の成果物

- ✅ F 33 件を 6 型に分類（32/33 = 97% カバー）
- ✅ アーキテクチャ: pre-router + escalate_to_cloud tool + Offload Wrapper + Return Router の 4 層
- ✅ 6 型ごとの cloud prompt template
- ✅ privacy 境界の明文化（送る/送らない/masking）
- ✅ assist vs overflow の使い分け
- ✅ コスト概算（月 $1-2/SAE）
- ✅ Stage 1-3 の実装段階

### 次フェーズへの引き継ぎ

**δ（仮称）= β 優先度に従う実装フェーズ**:

1. P7 (運用) + P5 (デリバリー) の A/D/E 中心実装（CronCreate 主体、lh360 カバー 94-97% の領域）
2. 実装中に F 発生頻度を計測
3. 頻度が十分高ければ γ Stage 1 に進む

γ 本体の実装着手 trigger:
- **A-E の実装が一巡した時** または
- **Gemma の F 遭遇で明確な user 不満が出た時**

どちらか早い方で Stage 1 の設計凍結解除。

---

## 12. 関連ドキュメント

- [lh360-usecase-pattern-analysis.md](./lh360-usecase-pattern-analysis.md) — β 分析（F 33 件の一次データ）
- [lh360-stocktake.md](./lh360-stocktake.md) — Phase 全体の実装観察ログ
- [../concepts/lh360-scope-reframing.md §5](../concepts/lh360-scope-reframing.md) — F offload の概念レベル議論
