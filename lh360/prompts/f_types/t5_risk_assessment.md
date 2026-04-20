# F-T5: リスク / 整合性評価

Task: {task_description}

## Target (document / condition set to evaluate)

{target}

## Standard (what "normal" or "acceptable" looks like)

{standard}

## Context snapshot

{context_data}

## Output format

Return ONLY the following JSON object (no prose, no markdown fences):

```json
{
  "risks": [
    {
      "location": "target 内のどの位置・条項・条件かを特定する (例: 第5条2項, 支払条件, スコープ欄 等)",
      "deviation": "standard から見たズレ・逸脱内容を 1-2 文で説明 (日本語)",
      "severity": "critical | moderate | low",
      "mitigation": "具体的な対処・修正案 (日本語)"
    }
  ],
  "overall_recommendation": "proceed | request_changes | escalate_to_legal",
  "rationale": "overall_recommendation の根拠 (日本語・2-3 文)",
  "showstoppers": ["先に進む前に必ず解消しなければならない項目 (日本語・location を参照)"]
}
```

Rules:
- `severity` は 3 値に厳密分類: `critical` (これが残ると取引不成立級)、`moderate` (交渉余地あり)、`low` (許容可能だが認識しておきたい)。
- `showstoppers` には severity=critical の項目から選んで入れる (全ての critical が必ずしも showstopper とは限らない — 業務継続に関わるものだけ)。空配列 `[]` でも可。
- `location` は target に実在する位置を指す。存在しない条項を捏造しない。target に明示的な条項番号がない場合はセクション見出しや要点で識別する。
- `deviation` は「standard ではこう、target ではこう」の対比が読み取れる書き方にする。standard が不十分で比較不能な項目は `risks` に含めず、回答末尾の `rationale` に「standard 情報不足」と明記する。
- `overall_recommendation`:
  - critical が 1 件でもあれば `request_changes` か `escalate_to_legal`
  - 法務判断が必須な項目 (知財・準拠法・紛争解決・損害賠償上限) が含まれる場合は `escalate_to_legal`
  - moderate のみなら `proceed` も可 (rationale で許容理由を述べる)
- 提供された target / standard 以外の業界慣行や一般論で判定しない。
