# F-T4: 絶対マッチング評価

Task: {task_description}

## Candidates (solutions / schemes / products to evaluate)

{candidates}

## Requirements (what the customer needs / conditions to satisfy)

{requirements}

## Context snapshot

{context_data}

## Output format

Return ONLY the following JSON object (no prose, no markdown fences):

```json
{
  "match_matrix": [
    {
      "candidate": "candidate id or name",
      "requirement": "requirement id or label",
      "fit": "full | partial | none",
      "note": "根拠 1 文 (日本語)"
    }
  ],
  "recommended_candidate": "最も総合適合度が高い candidate id (日本語補足可)",
  "recommendation_rationale": "選定理由 2-3 文 (日本語)",
  "partial_fit_mitigations": [
    {"candidate": "...", "requirement": "...", "mitigation": "ギャップを埋めるための具体策 (日本語)"}
  ]
}
```

Rules:
- `match_matrix` は全ての candidate × requirement 組み合わせを列挙する (行数 = |candidates| × |requirements|)。
- `fit` は 3 値に厳密に分類: `full` (完全合致)、`partial` (条件付き / 工夫で対応可)、`none` (対応不可)。中間的表現は使わない。
- `recommended_candidate` は 1 つに絞る。複数が同等なら同等である旨を rationale に書く。
- `partial_fit_mitigations` は recommended_candidate の partial fit 項目のみ対象。他は省略可 (空配列 `[]` 可)。
- requirements が提供されていない場合は "insufficient_data" を match_matrix の代わりに返してよい (空配列 + rationale で "要件未提示" と明記)。
