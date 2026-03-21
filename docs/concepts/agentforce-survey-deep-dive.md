# Agentforce × イベントアンケート対話型分析

作成日: 2026-03-21

## 構想

イベントアンケートの分析をAgentforceエージェントとの対話で行う。バッチ処理では1回の呼び出しで全体像を出す必要があるが、Agentforceなら角度を変えて何度も質問できる。RAG（Retriever）が質問ごとに異なるチャンクを返すことが、対話では多角的な探索を可能にする利点になる。

## 想定される対話例

```
ユーザー: 「スマートエネルギーWebセミナーの反響はどうだった？」
Agent: （ポジティブ寄りの全体傾向を回答）

ユーザー: 「ネガティブな意見はなかった？」
Agent: （回線品質、UI、時間配分等の不満を回答）

ユーザー: 「製造業の参加者に絞ると、どんなニーズがあった？」
Agent: （業種フィルタした回答）

ユーザー: 「その中でフォローアップ希望している人は？」
Agent: （具体的な担当者名・企業名を回答）

ユーザー: 「じゃあノヴァテックの回答者について詳しく教えて」
Agent: （Data Graph経由で取引先 → 担当者 → アンケート回答を横断して回答）
```

## 既存インフラの活用

今回のパイプライン実装で構築済みのアセットがそのまま使える：

| アセット | 用途 |
|---|---|
| Search Index（EventSurveySearchIndex） | Retrieverの検索基盤 |
| Retriever（EventSurveySearchIndex_1Cx_dKv65a92b35） | 対話型検索のデータソース |
| Data Graph（EventSurveyAccountGraph） | Account → Individual → Contact Point Email → EventSurvey の横断クエリ |
| EventSurvey DMO | 構造化データのクエリ対象 |

## 実装方針

1. Agentforceエージェントに「イベントアンケート分析」トピックを追加
2. アクションとして既存のRetriever付きPrompt Template（`EventSurveyAnalysis`）を登録
3. 必要に応じてData Graph検索のApexアクションも追加（構造化クエリ用）

## なぜAgentforceが活きるか（RAGアンチパターンからの学び）

バッチ処理でRAGを使うと「聞き方によって見える景色が変わる」ことが欠点になるが、対話型ではこれが利点になる：

- Retrieverは質問の角度ごとに異なるチャンクを返す
- ユーザーが「ポジティブは？」「ネガティブは？」「業種別は？」と深掘りすることで、RAGの特性を活かした多角的な分析が可能
- 1回の呼び出しで全体像を出す必要がないため、Retrieverの返却チャンク数制限が問題にならない

詳細: `docs/reference/rag-vs-direct-query-lessons.md`
