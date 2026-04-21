# F-T1: 機会評価 / 優先順位付け

Task: {task_description}

## Candidates to evaluate

{candidates}

## Evaluation criteria

{criteria}

## Context snapshot (SSoT data already collected)

{context_data}

## Output format

Return ONLY the following JSON object (no prose, no markdown fences):

```json
{
  "ranked": [
    {"id": "candidate id from above", "score": 1-10, "rationale": "1-2 sentences in Japanese citing specific data points"}
  ],
  "top_actions": [
    {"id": "...", "next_action": "concrete action the SAE can take this week, in Japanese"}
  ],
  "insufficient_data": ["criterion names that could not be assessed from the provided context"]
}
```

Rules:
- `ranked` must include **every** candidate, ordered by score descending. Ties broken by id alphabetical.
- `top_actions` covers the top 3 (or fewer if fewer candidates).
- `insufficient_data` lists criteria where the context did not contain enough information. Empty array `[]` if all assessable.
- Rationale must reference concrete fields from context (e.g., "StageName=Negotiation かつ LastModifiedDate が 30 日前"). Do not invent metrics.
