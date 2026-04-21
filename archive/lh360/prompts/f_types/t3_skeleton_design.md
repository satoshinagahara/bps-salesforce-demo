# F-T3: 骨格設計 / スケルトン生成

Task: {task_description}

## Goal

{goal}

## Audience

{audience}

## Constraints

{constraints}

## Reference materials (existing related work / SSoT data)

{references}

## Output format

Return ONLY the following JSON object (no prose, no markdown fences):

```json
{
  "outline": [
    {
      "section": "セクション名 (日本語)",
      "purpose": "このセクションが達成する目的 (1-2 文・日本語)",
      "key_points": ["要点 1", "要点 2", "..."],
      "data_needed": ["SSoT から追加で引くべきデータや、外部から調達すべき情報"]
    }
  ],
  "recommended_order": "章立ての推奨順序とその理由 (日本語・3-5 文)",
  "risks": ["現時点の骨格で想定されるギャップやリスク (日本語)"]
}
```

Rules:
- `outline` は 4-8 セクションを目安とする。細分化しすぎない。
- `key_points` は各セクション 3-5 項目、具体的な論点・データ・主張単位で書く。
- `data_needed` は空配列 `[]` でも可 (提供 references で足りる場合)。
- `risks` はこの骨格で抜けやすい論点を指摘する。少なくとも 2 項目出すこと。
- 提供された references / context 以外の顧客固有情報を捏造しない。
