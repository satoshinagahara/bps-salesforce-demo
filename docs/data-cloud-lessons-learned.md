# Data Cloud 実装知見（2026-03-18 イベントアンケートRAGパイプライン構築時）

## 1. DLOカテゴリの選択がすべてを決める

Data Cloud でデータストリームを作成する際、DLO（Data Lake Object）に割り当てる**カテゴリ**が最も重要な設計判断。カテゴリによって以下が制約される：

| カテゴリ | マッピング可能なDMO | Identity Resolution | 用途 |
|---|---|---|---|
| **プロファイル** | Individual, Contact Point Email/Phone/Address | 参加可能 | 人物・顧客マスター情報 |
| **エンゲージメント** | イベント系DMO、カスタムエンゲージメントDMO | 参加不可（リレーション経由で間接紐付け） | 行動・インタラクションデータ |
| **その他** | Account, Product等の参照データ系 | 参加不可 | マスターデータ、参照テーブル |

### 実体験で判明したこと

イベントアンケートCSV（メールアドレス＋回答内容）を「エンゲージメント」カテゴリで取り込んだ結果：
- **マッピング画面でIndividual / Contact Point Emailが選択肢に表示されない**
- **ID解決ルールセットを実行しても統合率0%**（EventSurveyのレコードがIndividualにリンクされないため）

### 正しいアプローチ

外部データにメールアドレス等の識別情報が含まれ、CRMデータと名寄せしたい場合は**DLOを2つに分割**する：

1. **プロファイルDLO**（プロファイルカテゴリ）: `attendee_email` + `attendee_name` → Individual DMO + Contact Point Email DMOにマッピング
2. **エンゲージメントDLO**（エンゲージメントカテゴリ）: アンケート回答内容 → カスタムDMOにマッピング → Contact Point Emailへのリレーションで紐付け

これによりID解決が正常に機能し、メールアドレスの完全一致でCRM Contact/Leadと統合される。

### 代替アプローチ（今回採用）

DLO分割が手間な場合、**Data Graphのリレーション結合で代替**可能：
- EventSurveyの`attendee_email`からContact Point Emailの`Email Address`へリレーションを定義
- Data Graphで `Account → Contact Point Email → EventSurvey` を結合
- 統合プロファイルは生成されないが、取引先別のアンケートデータ取得は実現できる

---

## 2. Data Cloudの個人データ正規化モデル

Data CloudはCRMのContact/LeadをそのままDMOにマッピングするのではなく、**正規化された個人データモデル**に変換する。

```
Individual（個人の統合エンティティ）
  ├── Contact Point Email（メールアドレス、1:N）← Party フィールドで Individual を参照
  ├── Contact Point Phone（電話番号、1:N）
  ├── Contact Point Address（住所、1:N）
  └── [エンゲージメント系DMO] ← Individual への外部キーで紐づく
```

- CRM ContactのEmailは `Contact Point Email` DMOに格納される（Contact DMO内ではない）
- Lead/ContactのFirst Name/Last Nameは `Individual` DMOの `Person Name` にマッピングされる
- この正規化により、Lead/Contact/外部データなど複数ソースの同一人物を統合できる

---

## 3. Search IndexはDMO単位、Data Graphは構造化コンテキスト

| コンポーネント | 対象 | 用途 |
|---|---|---|
| **Search Index** | 個別DMO | テキストフィールドのベクトル化（セマンティック検索用） |
| **Retriever** | Search Index | セマンティック検索を実行し、Prompt Templateに結果を渡す |
| **Data Graph** | 複数DMOの結合ビュー | Prompt Templateに構造化された関連データを渡す |

- Search IndexはData Graphに対して直接作成**できない**。Data Graph内の個別DMOに作成する
- Prompt Templateでは**Retriever（非構造化テキスト検索）**と**Data Graph（構造化データ）**を併用可能
- Retriever = 「関連するテキストを見つける」、Data Graph = 「関連するレコード群を確実に渡す」という役割分担

---

## 4. Salesバンドルの自動マッピング

CRMオブジェクトをData Cloudに同期する際、「Salesバンドル」を使うとデータストリーム作成後に**自動でDMOマッピングとデータ取り込みが実行される**。

- 手動でマッピングしようとすると、自動処理とバッティングして保存エラーが発生することがある
- 自動マッピングの精度は高くない場合がある（項目名の類似性ベースで誤マッピングすることがある）
- ただし主要な項目（Id, Name, Email, Website等）は概ね正しくマッピングされる

---

## 5. S3コネクタの運用Tips

- **ワイルドカード**: ファイル名に `*.csv` を指定すると、フォルダ内の全CSVを取り込める
- **スキーマ統一が必須**: ワイルドカードで複数ファイルを取り込む場合、全ファイルのカラム構成が一致している必要がある
- **差分検出**: Incrementalモードではファイルの最終更新日時で差分を検出。ファイルを上書きアップロードすると全体が再取り込み対象になる
- **Primary Key**: Upsert動作にはPrimary Keyの指定が必須（例: `survey_id`）

---

## 6. Search Indexの構築

- 構築には15〜20分かかる（レコード数による）
- 日本語テキストには `Hybrid` モード + `Multilingual E5 Large` エンベディングモデルが推奨
- Retriever作成はSearch Indexのステータスが「準備完了」になってから
- Prompt TemplateはMetadata APIデプロイ後にUI（Prompt Builder）で手動Activateが必要
