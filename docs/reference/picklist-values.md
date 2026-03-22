# 選択リスト値リファレンス

このorgの選択リスト値は**全て日本語**で設定されている。データ作成時に英語値を使うとエラーになるため、事前に `sf sobject describe` で確認すること。

以下は主要な選択リスト値の一覧（頻出するもの）。

## BOM関連

| オブジェクト | フィールド | 値 |
|---|---|---|
| BOM_Line__c | Component_Type__c | アセンブリ / 部品 / 素材 / ファントム |
| BOM_Line__c | Unit_of_Measure__c | 個 / kg / m / L / 式 / セット |
| BOM_Part__c | Make_or_Buy__c | 内製 / 購買 / 外注 |
| BOM_SubComponent__c | Material_Type__c | 金属 / 樹脂 / 電子部品 / ゴム / その他 |
| BOM_SubComponent__c | Process_Type__c | 切削 / 溶接 / 組立 / 外注 / 購買 |
| BOM_Header__c | BOM_Type__c | 製造BOM |
| BOM_Header__c | Status__c | 承認済 |

> **注意**: 上記は初期構築時点の値。フィールド追加・値追加が行われている可能性があるため、不明な場合は `sf sobject describe -s <ObjectName> --target-org <username>` で最新値を確認すること。
