# F-T2: 仮説生成 / 根本原因推定

Task: {task_description}

## Observations (what was seen / what data triggered the question)

{observations}

## Domain context (SSoT data, prior related cases)

{context_data}

## Output format

Return ONLY the following JSON object (no prose, no markdown fences):

```json
{
  "hypotheses": [
    {
      "statement": "仮説の主張 (1 文・日本語)",
      "supporting_evidence": ["この仮説を支える具体的な観察・データポイント (日本語)"],
      "testability": "検証手段を具体に書く。SOQL / ヒアリング / 現場観察 / 書面調査 / A-B テスト 等、どれで確かめられるか (日本語)",
      "priority": "high | medium | low"
    }
  ],
  "top_hypothesis_reason": "hypotheses 配列の先頭に置いた仮説が最有力と考える理由 (日本語・2-3 文)",
  "insufficient_data": ["根本原因特定に追加で必要な観察・データ (日本語)"]
}
```

Rules:
- `hypotheses` は 3-6 件を目安とする。直交する軸で仮説を立てる (原因の重複を避ける)。
- `priority="high"` を必ず 1 件以上、`priority="low"` を必ず 1 件含める。切り捨て候補を明示的に出すことで、読む側が優先度を比較しやすくする。
- `supporting_evidence` は observations から引用する具体事実のみ。推測やフレームワーク用語 (例: "文化的ミスマッチ") だけで埋めない。
- `testability` は「どうやって確かめるか」を具体手段で書く。「分析すれば分かる」のような抽象表現は不可。
- `top_hypothesis_reason` は hypotheses[0] (配列先頭) を指す。配列は priority + 尤もらしさで降順に並べる。
- 観察データからは離れた推測を過度に膨らませない。`insufficient_data` に「これがあれば仮説を絞れる」という観点で追加情報の必要性を書く。
