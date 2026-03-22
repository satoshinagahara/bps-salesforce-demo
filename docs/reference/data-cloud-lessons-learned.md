# Data Cloud 実装知見（2026-03-18 イベントアンケートRAGパイプライン構築時）

> **注**: DLOカテゴリ・個人データ正規化モデル・Search Index/Data Graph・S3コネクタ・queryv2・データストリーム再作成等の**一般的な技術知見**は `salesforce-admin` スキルの references に集約済み。本ファイルは**このプロジェクト固有の体験記録**のみ記載。

---

## 1. DLOカテゴリ選択の失敗と対処（イベントアンケート）

イベントアンケートCSV（メールアドレス＋回答内容）を「エンゲージメント」カテゴリで取り込んだ結果：
- マッピング画面でIndividual / Contact Point Emailが選択肢に表示されない
- ID解決ルールセットを実行しても統合率0%

### 今回採用した代替アプローチ

DLO分割ではなく、**Data Graphのリレーション結合**で対処した：
- EventSurveyの`attendee_email`からContact Point Emailの`Email Address`へリレーションを定義
- Data Graphで `Account → Contact Point Email → EventSurvey` を結合
- 統合プロファイルは生成されないが、取引先別のアンケートデータ取得は実現できた

---

## 2. Salesバンドルの自動マッピング

CRMオブジェクトをData Cloudに同期する際、「Salesバンドル」を使うと自動でDMOマッピングとデータ取り込みが実行される。この環境で経験した注意点：

- 手動でマッピングしようとすると、自動処理とバッティングして保存エラーが発生した
- 自動マッピングの精度は高くない場合がある（項目名の類似性ベースで誤マッピング）
- ただし主要な項目（Id, Name, Email, Website等）は概ね正しくマッピングされた
