# Agentforce アーキテクチャガイド

**作成日**: 2026-03-24
**目的**: このデモ環境でのAgentforce運用方針と、設計判断の根拠を記録する

---

## 1. 現環境のAgent構成

| Agent | ステータス | Topic数 | 用途 |
|---|---|---|---|
| 製品・調達・品質マネジメントエージェント（BOM_Analysis_Agent） | ✅ Active | 2 | BOM分析・サプライヤーリスク |
| Agentforce Employee Agent | ❌ Inactive | 2 | 取引先分析・General FAQ |
| RAG Test Agent | ❌ Inactive | - | RAG検索テスト用 |

### 設計判断: 1 Agent集約方式を採用

BOM_Analysis_Agent に全Topicを集約する方針。理由:

- 1 Agent あたり最大15 Topicの上限に対して、現状2 + 計画2-3 = 十分余裕あり
- デモ環境では1人のユーザーが全機能を使う
- Agent名は必要に応じて汎用的な名称に変更する
- Employee Agent の Topic（取引先分析、General FAQ）も移植予定

---

## 2. 確立されたアクションパターン

この環境で動作確認済みのパターン：

```
Topic → Apex Action（データ収集・JSON返却）→ Prompt Template（分析・示唆生成）
```

### 実装済みの例

| Topic | Action 1 (Apex) | Action 2 (Prompt Template) |
|---|---|---|
| 取引先分析 | AccountInsightFullAnalysis → JSON | AccountInsightSuggestions → 示唆 |
| サプライヤーインパクト | BOMAnalysisGetSupplierImpact → JSON | BOMSupplierImpactAnalysis → レポート |
| 製品BOM分析 | BOMAnalysisGetProductBOM → JSON | BOMSupplierImpactAnalysis → レポート |

### データ量による分岐

- **小〜中データ（数KB以下）**: 2アクション分離（Apex → Prompt Template）
- **大データ（数KB以上）**: Apex内でConnectApi経由でPrompt Template呼び出し（1アクション統合）

---

## 3. 複数Agent共存の仕様

### UI挙動
- 複数Employee Agentが有効な場合、ドロップダウンで切替
- 表示されるAgentはパーミッションセット/プロファイルで制御
- 1 org あたり最大20 Agent

### 上限

| 項目 | 上限 |
|---|---|
| Agent数 / org | 20 |
| Topic数 / Agent | 15 |
| Action数 / Topic | 15 |

---

## 4. Topic設計のポイント

### ルーティング精度を左右する要素

Topic数よりも**設計品質**が重要：

| 要素 | 影響 | 推奨 |
|---|---|---|
| Topic名（masterLabel） | Agent LLMがトピック選択する際の第一判断材料 | アクション指向の名前（「商談類似分析」○、「サポート」×） |
| 分類記述（description） | いつこのTopicを使うべきかの判断材料 | 「ユーザーが〜を知りたい時」形式で具体的に |
| スコープ（scope） | Topicが対応する/しない範囲の定義 | 「Your job is solely to...」で明確に境界を示す |
| 発話例（utterances） | ルーティング精度向上 | 実際の質問パターンを5-10個 |

### Instructions の書き方

- 実行順序を番号付きで明示
- アクション間のデータ受け渡しを具体的に指示
- Agent LLMは Instructions に忠実に従う

### 同一セッション内でのAction再実行の強制（重要・実証済み）

Agent LLM（ReActプランナー）は、同一セッション内で過去にActionを実行済みの場合、2回目以降の質問に対して**Actionを再実行せず、1回目の出力テキストから直接回答を生成する**ことがある。

**問題が起きるケース：**
- ユーザーの質問内容（userQuery）によって分析の焦点が変わるAction
- 1回目「委員会を突破するには？」→ 詳細レポート
- 2回目「競合に勝つには？」→ Actionを呼ばず、1回目のレポートから箇条書きで要約してしまう

**対策：** Instructionsに「毎回必ず実行」「質問が異なれば結果が変わる」と明示する。

```
## NG: 再実行されない場合がある
1. 「分析アクション」を実行する
2. 結果をユーザーに返す

## OK: 再実行が強制される（実証済み）
1. ユーザーが質問をするたびに、必ず「分析アクション」を実行する
   - 過去の会話で既に結果を取得していても、質問が異なればアクションを再実行すること
   - opportunityIdには現在表示中の商談のIDを渡す
   - userQueryにはユーザーの質問内容をそのまま渡す（質問によって分析の焦点が変わるため）
2. アクションの出力（分析レポート）をそのままユーザーに返す
```

**ポイント：** `userQuery`パラメータの存在が再実行の合理的な理由となる。「質問によって分析の焦点が変わるため」という説明がAgent LLMに再実行の必要性を理解させる。

---

## 5. レコードコンテキストの取得

Agent Topic はレコードページのコンテキストを自動認識しない。以下の方法でレコードIDを取得：

### 推奨: Apex Actionの入力変数

```apex
public class MyAction {
    public class Input {
        @InvocableVariable(required=true description='対象レコードのID')
        public String recordId;
    }

    @InvocableMethod(label='My Action')
    public static List<Output> execute(List<Input> inputs) {
        // recordId はレコードページから自動注入される
    }
}
```

- Topic Instructions に「現在表示中のレコードのIDを渡す」と明示する
- Agent LLMが文脈を理解し、適切にIDを渡す

---

## 6. 既知の制約（この環境固有）

- `sf agent create` でEmployee Agent（InternalCopilot）は作成不可 → UIで作成
- Metadata APIでTopicをデプロイしても InternalCopilot には反映されない → UIのAgent Builderで追加
- Agent LLMがレコードID解決時に `CA-0000` 形式の名前を渡すことがある → Name→ID変換フォールバック実装済み
