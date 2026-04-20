# F-T6: 構造マッピング / ポジショニング

Task: {task_description}

## Entities (items to position on the map)

{entities}

## Dimensions (axes / criteria to position them on)

{dimensions}

## Context snapshot

{context_data}

## Output format

Return ONLY the following JSON object (no prose, no markdown fences):

```json
{
  "positioned": [
    {
      "entity": "entity id or name",
      "coordinates": {
        "<dimension_name_1>": "値 (定性ラベル または 1-5 のスコア)",
        "<dimension_name_2>": "..."
      },
      "note": "位置付けの根拠 1-2 文 (日本語)"
    }
  ],
  "clusters": [
    {
      "members": ["entity id list"],
      "characterization": "このクラスタが共通して持つ特徴 (日本語・1-2 文)"
    }
  ],
  "strategic_implication": "このマップから読み取れる戦略的含意 (日本語・2-3 文)",
  "unmapped": ["dimensions 情報が不足して位置付けできなかった entity (日本語補足可)"]
}
```

Rules:
- `coordinates` のキーは `dimensions` で提示された軸名と厳密に一致させる (順序も同じ)。軸追加・改名は禁止。
- 値の表現は dimensions 側に尺度指定がある場合は従う。指定がない場合は **5 段階スコア (1-5)** または **定性ラベル 3 値** (例: 高/中/低) に統一し、どちらを採用したか `note` で 1 度だけ明記する。混在は禁止。
- `clusters` は 2-4 グループが目安。各 cluster には 2 entity 以上を含める (1 entity の cluster は作らない)。どの cluster にも属さない outlier は `strategic_implication` で言及する。
- `unmapped` は dimensions の値が context から導出できなかった entity を入れる。空配列 `[]` でも可。
- `strategic_implication` は「この map から SAE が次に打つべき一手」を具体に書く。抽象的な観察 (例: "多様な分布が見られる") で終わらせない。
- 提供された entities / dimensions / context_data に無い情報で位置付けを補完しない。
