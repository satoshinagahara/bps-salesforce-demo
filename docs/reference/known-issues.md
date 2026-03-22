## LWC
- **App Builder表示名**: meta.xmlの`masterLabel`でApp Builder表示名が変わる。混乱を避けるため使わないか、設定時はユーザーに伝える
- **targets指定は配置場所ごとに必須**: `lightning__RecordPage`のみ指定したLWCはホームページのApp Builderに表示されない

## Metadata API / Deploy
- **OpportunityStage等のlabelはMetadata APIで変更不可**: 翻訳ワークベンチ（Translation Settings）を使う
- **ソーストラッキングなし**: `--ignore-conflicts` フラグで対処
- **FlexiPageのレコードタイプ別割当はUIが確実**: Lightning App Builder → Activation から手動割当

## Permission Set
- **FLS問題**: カスタムオブジェクト/フィールドデプロイ後、FLSが未設定だとSOQLで見えない。`BOM_Full_Access` 権限セットに追加
- **MD関係項目はFLS設定不可**: `fieldPermissions`に含めるとデプロイエラー。除外すること
- **必須項目(required=true)もFLS設定不可**: 同上
- **XML要素順序**: classAccesses → fieldPermissions → hasActivationRequired → label → objectPermissions → recordTypeVisibilities
- **Knowledge__kav RecordTypeはPermissionSetで割当必要**: RecordTypeVisibilitiesに追加しないとDML時にエラー

## Object / Field
- **Product2はMD親になれない**: BOM_Header__cのProduct__cはLookup(SetNull)で実装
- **子リレーション名はdescribeで確認必須**: 命名規則から推測せず `sf sobject describe` で確認
- **数式フィールド**: Percent型は小数返却（75%→0.75）

## Apex / API
- **ConnectApi temperatureはApexでのみ設定可能**: `additionalConfig.temperature`で指定。推奨値: 分析=0.2, メール=0.4, クイズ=0.7
- **ConnectApi.applicationName必須**: `'PromptBuilderPreview'` がないとPrompt Template呼出しが失敗
- **Knowledge__kav SOSLにはLanguage WHERE必須**: orgデフォルト`en_US`なら`AND Language = 'en_US'`を付ける
- **SOSLはDraft記事を検索しない**: SOQL or Apex内マッチングが必要
- **Prompt TemplateはデプロイだけではActivateされない**: Prompt Builder UIで手動Activate必要

## Agentforce

> **注**: Agentforceの一般的な技術制約（メタデータ構造、CLI制限、アーキテクチャ指針等）は `salesforce-admin` スキルの `metadata-agentforce.md` に集約済み。以下は**このorg固有の問題・運用メモ**のみ記載。

### このorg固有の問題
- **Agentforce（デフォルト）を使用中**: 従業員エージェントへの移行が推奨されているが未実施
- **Agentforce入力のID解決**: Agent LLMはCA名（CA-0000）を渡すことがある。Name検索→ID変換のフォールバックをApex側で実装済み
- **分析系プロンプトは「事実のみ」スタイル**: 「提案は含めない」を明示する運用にしている
