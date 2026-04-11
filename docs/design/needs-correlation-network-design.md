# ニーズ相関ネットワーク（needsCorrelationNetwork）設計ドキュメント

## 1. コンセプト

営業活動から蓄積された `Needs_Card__c`（ニーズカード）同士の**テキスト類似性**を力学モデルで可視化し、以下の発見を支援する LWC。

- **業界横断で共通するニーズ**の発見（異業種でも本質的に同じ課題を抱えているケース）
- **特定業界内で頻出するニーズクラスタ**の把握
- あるニーズカードから関連ニーズへの探索（グラフノードをクリックしてレコード遷移）

## 2. 機能要件

| # | 要件 | 実現方法 |
|---|---|---|
| 1 | ニーズカード間の類似関係を直感的に俯瞰できる | Canvas 上の Force-Directed Graph |
| 2 | 業界ごとに色分けして一目で構造が分かる | 業界ごとのカラーマップ |
| 3 | 同業界ノードが自然にクラスタリングされる | 初期配置を業界別クラスタ円 + 同業界間の弱い引力 |
| 4 | 業界でフィルタして探索できる | 凡例ピルのクリックトグル |
| 5 | ノード詳細を素早く確認できる | ホバーでツールチップ表示 |
| 6 | 詳細を見たければレコードに遷移できる | クリックで `standard__recordPage` ナビゲーション |
| 7 | 類似度の閾値・ノード数をユーザーが調整できる | コンボボックスで動的リフレッシュ |
| 8 | 異業種共通ニーズをサマリーで見せる | `crossIndustryInsights` パネル |

## 3. アーキテクチャ

```
┌─────────────────────────────┐        ┌─────────────────────────────┐
│ needsCorrelationNetwork     │ @wire  │ NeedsCorrelationController  │
│ (LWC)                       │───────▶│ (Apex)                      │
│                             │        │                             │
│ - Canvas 描画 (Force sim)   │        │ - SOQL: Needs_Card__c       │
│ - 業界カラーマップ          │        │ - bi-gram Jaccard 類似度    │
│ - ツールチップ / フィルタ   │        │ - k-NN エッジ削減           │
└─────────────────────────────┘        │ - 異業種ペア集計            │
                                       └─────────────────────────────┘
                                                     │
                                                     ▼
                                       ┌─────────────────────────────┐
                                       │ Needs_Card__c               │
                                       │ (Title, Description,        │
                                       │  Customer_Voice,            │
                                       │  Account_Industry, 等)      │
                                       └─────────────────────────────┘
```

### ファイル構成

- [force-app/main/default/classes/NeedsCorrelationController.cls](../../force-app/main/default/classes/NeedsCorrelationController.cls) — Apex Controller
- [force-app/main/default/lwc/needsCorrelationNetwork/](../../force-app/main/default/lwc/needsCorrelationNetwork/) — LWC bundle (js / html / css / meta)

## 4. サーバーサイド設計（Apex）

### 4.1 エンドポイント

```apex
@AuraEnabled(cacheable=true)
public static Map<String, Object> getCorrelationData(
    Integer minSimilarity,  // 類似度の閾値（%）
    Integer maxNodes        // 最大ノード数
)
```

### 4.2 レスポンス構造

```jsonc
{
  "nodes": [
    {
      "id": "a0X...",
      "label": "ニーズタイトル",
      "industry": "Electronics",
      "accountName": "XX電機",
      "needType": "機能要望",
      "priority": "高",
      "businessImpact": "...",
      "productFamily": "..."
    }
  ],
  "edges": [
    { "from": "a0X...", "to": "a0Y...", "weight": 42 }
  ],
  "industryCount": { "Electronics": 12, "Utilities": 8, ... },
  "crossIndustryInsights": [
    { "pair": "Electronics × Utilities", "count": 3 }
  ]
}
```

### 4.3 類似度計算: bi-gram Jaccard

**採用理由**: 組織に日本語形態素解析器が無い前提。空白区切りの単語ベース Jaccard は日本語本文をほぼ 1 トークン化してしまい機能しないため、**2文字 n-gram**で代替する。

```
類似度(A, B) = |bigrams(A) ∩ bigrams(B)| / |bigrams(A) ∪ bigrams(B)| × 100
```

対象テキストは `Title__c + Description__c + Customer_Voice__c` を連結。記号・句読点・スペースを除去して bi-gram 化。

実装: `toBigrams()` / `jaccardSimilarity()`

### 4.4 k-NN エッジ削減（密度対策）

全ペア計算して閾値以上のエッジを残すと、50 ノードでも容易に 1000 本超になり**視覚的にノイズ**になる。そこで：

1. 全ペア類似度を閾値フィルタ
2. 各ノードについて、そのノードに関わるエッジを類似度 DESC でソート
3. **各ノードあたり上位 K (=3) 本のみを残す**
4. いずれかのノードの上位 K に入ったエッジの集合（Union）を最終エッジとする

これにより「最も強い関係だけが残る疎なグラフ」になり、構造が見える。`TOP_N_EDGES_PER_NODE` 定数で調整可能。

### 4.5 SOQL

```sql
SELECT Id, Name, Title__c, Need_Type__c, Priority__c,
       Account__c, Account__r.Name,
       Account_Industry__c, Business_Impact__c,
       Product__c, Product__r.Family,
       Description__c, Customer_Voice__c, CreatedDate
FROM Needs_Card__c
WHERE Status__c != '却下' AND Account_Industry__c != null
ORDER BY CreatedDate DESC
LIMIT 200
```

- `Account_Industry__c != null` は**業界値 null のレコードが先頭を占めて業界フィルタが機能しなくなる**問題への対策
- 200 件取得してから `maxNodes` で頭を切り出す構成

### 4.6 異業種共通ニーズ分析

`analyzeCrossIndustry()` は最終 edges を走査し、両端ノードの業界が異なるペアの出現回数を集計。2 件以上のペアを `crossIndustryInsights` として返す。

## 5. クライアントサイド設計（LWC）

### 5.1 状態管理

| フィールド | 用途 |
|---|---|
| `rawNodes / rawEdges` | Apex から取得した元データ（フィルタ変更時の再構築用） |
| `nodes / edges` | 現在グラフに表示中のオブジェクト（x,y,vx,vy などの物理状態含む） |
| `enabledIndustries` | 有効化中の業界の Set — 凡例クリックで切替 |
| `industryCount` | 凡例表示用の業界別件数 |
| `hoveredNode / selectedNode / draggingNode` | インタラクション状態 |
| `isStable` | シミュレーション停止フラグ（最適化用） |

### 5.2 業界カラーマップ

`INDUSTRY_META` 定数で **実データの英語 Picklist 値**をキーに `{ color, label }` を定義。日本語ラベルも併記するため、UI には日本語が表示される。

```js
const INDUSTRY_META = {
  'Utilities':          { color: '#0891b2', label: '電力・ガス' },
  'Electronics':        { color: '#2563eb', label: 'エレクトロニクス' },
  'Trading':            { color: '#d97706', label: '商社' },
  'Government':         { color: '#475569', label: '官公庁' },
  'Chemicals':          { color: '#7c3aed', label: '化学' },
  'Financial Services': { color: '#059669', label: '金融サービス' },
  'Energy':             { color: '#dc2626', label: 'エネルギー' },
  // ... 他
};
```

未定義の業界値は `DEFAULT_META`（灰色・"その他"）にフォールバック。

### 5.3 Force-Directed Simulation

`updatePositions()` が毎フレーム呼ばれ、以下の力を合成：

| 力 | 式 | 強度 |
|---|---|---|
| **斥力** (全ノード間) | `repulsion / dist²` | `repulsion = 4500` |
| **バネ引力** (エッジ両端) | `(dist - idealDist) × k` | `k = 0.015, idealDist = 130` |
| **同業界凝集力** | `0.4 / dist`（dist > 180 のみ） | 弱 |
| **中心重力** | `(center - pos) × 0.003` | 非常に弱 |

- `damping = 0.85` で速度減衰
- `maxVelocity < 0.15` かつドラッグ中でなければ `isStable = true` でシミュレーションを停止し CPU 節約

### 5.4 初期配置：業界別クラスタ円

単純ランダムや単一大円では収束が遅く、かつ業界クラスタが見えづらい。初期配置段階で**業界ごとに小クラスタ円を作り、それらを外周大円上に配置**する。

```
    [業界A]           [業界B]
         \          /
          \        /
         ┌─────────┐
         │ 中央    │
         └─────────┘
          /        \
         /          \
    [業界C]           [業界D]
```

- 外周半径: `min(width, height) × 0.38`
- 各クラスタ内半径: `30 + √N × 14`
- 業界が 1 つのみの場合はクラスタを中央に配置（右寄り問題の対策）

### 5.5 描画: ラベル戦略

50 ノード全てにラベルを常時描画すると**文字が団子状に重なり判読不能**だった。そこで以下に変更：

- ノード数 ≤ 20: 全ノードにラベル表示
- それ以上: **ホバー中のノード + その接続先ノード + 選択中ノード**のみラベル表示
- ホバー中は関連外ノードを `alpha = 0.25` に dim して関連サブグラフを強調
- 関連エッジは青 (`#2563eb`) でハイライト
- ラベル周りに白ハローを描画して背景に馴染むのを防止

### 5.6 エッジ描画

- 線幅 ∝ 類似度（`max(0.6, weight / 25)`）
- 透明度 ∝ 類似度（`min(1, weight / 50) × 0.45`）
- ホバー中は関連エッジのみ `alpha = 0.9` で強調

### 5.7 インタラクション

| 操作 | 挙動 |
|---|---|
| ホバー | ツールチップ表示 / 接続先ハイライト |
| ドラッグ | ノード位置固定操作（物理シミュは再開） |
| クリック | `standard__recordPage` ナビゲーション |
| 凡例クリック | 業界ごとの表示 ON/OFF |
| 類似度/ノード数変更 | Apex 再取得 → グラフ再構築 |

**ドラッグ誤クリック対策**: `handleMouseDown` で `dragDistance = 0` にリセットし、`handleMouseMove` で累積。`handleClick` では `dragDistance > 5` なら無視することで、ノードを動かして離した際の意図しない画面遷移を防止。

### 5.8 Canvas サイズ取得の安定化

`renderedCallback` 初回時、`container.clientWidth` がまだ 0 になる場合がある。`requestAnimationFrame` で 1 フレーム遅延させ、`canvas.getBoundingClientRect()` から実寸を取得してから `rebuildGraph()` を呼ぶことで、初期レンダリング時にグラフが右寄りに表示される問題を回避。

## 6. パラメータ調整ガイド

| パラメータ | 既定値 | 変更時の効果 |
|---|---|---|
| `minSimilarity` (UI) | 15% | 上げると疎、下げると密。日本語 bi-gram の特性上 10-25% が実用レンジ |
| `maxNodes` (UI) | 50 | 100 にすると処理量は約 4 倍（O(n²)）、描画負荷も増大 |
| `TOP_N_EDGES_PER_NODE` (Apex) | 3 | 増やすとグラフが密になる。2 で完全に骨格のみ、5 で十分見通しが利く |
| `repulsion` (JS) | 4500 | 上げるとノードが離れる |
| `idealDist` (JS) | 130 | エッジ両端ノード間の理想距離 |

## 7. 性能考慮

- SOQL: 1 クエリのみ、LIMIT 200
- Apex: O(n²) の類似度計算。`maxNodes = 100` で 4,950 ペア計算。bi-gram Set の `retainAll` / `addAll` の負荷がボトルネック
- Canvas 描画: `requestAnimationFrame` ベースでシミュレーションを安定時停止（`isStable`）により CPU 節約
- `@wire(cacheable=true)` により同一パラメータでの再アクセスは即時返却

## 8. 既知の限界と将来改善

| 項目 | 現状 | 改善案 |
|---|---|---|
| 類似度アルゴリズム | bi-gram Jaccard | Data Cloud のベクトル検索 / Embedding ベース類似度 |
| 業界ラベル | 英語→日本語のハードコード | Picklist メタデータから動的取得 |
| レイアウト | 毎回クラスタ配置から収束 | ノード位置をキャッシュして再描画高速化 |
| 大規模データ | maxNodes = 100 が実用上限 | WebGL 化 / エッジ間引きの動的調整 |
| FLS | 権限セットで対応前提 | `Schema.sObjectType.Needs_Card__c` での明示チェック |

## 9. 運用・保守

- **デプロイ対象**: `NeedsCorrelationController` + `needsCorrelationNetwork` バンドル
- **依存オブジェクト**: `Needs_Card__c`（`Title__c`, `Description__c`, `Customer_Voice__c`, `Account_Industry__c`, `Account__c`, `Product__c`, `Status__c`）
- **権限セット**: `BOM_Full_Access` に `Needs_Card__c` の項目参照権限が必要
- **配置先**: AppPage / HomePage / RecordPage いずれも利用可能（`isExposed=true`）

## 10. 改修履歴

| 日付 | 内容 |
|---|---|
| 2026-04-11 | 初期デプロイ後の改善ラウンド：①業界カラーマップを実データ（英語Picklist）に対応、②類似度計算を bi-gram Jaccard 化、③k-NN エッジ削減 (Top-3)、④ホバー時ラベル表示、⑤業界別クラスタ初期配置、⑥動的凡例＋フィルタ、⑦ツールチップ、⑧Canvas サイズ取得安定化、⑨ドラッグ誤クリック防止、⑩SOQL で `Account_Industry__c != null` フィルタ追加 |
