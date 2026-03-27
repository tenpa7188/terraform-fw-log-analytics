# Parquet 化方式の比較メモ

## 1. 目的
- FW ログの `text + gzip + RegexSerDe` 構成から、将来的に Parquet 化するための方式比較を行う。
- 要件定義・設計フェーズで、候補方式の違いを説明しやすくする。
- 本資料では、次の 3 方式を比較対象とする。
  - `1. Athena CTAS / INSERT INTO`
  - `2. AWS Glue ETL Job`
  - `3. AWS Lambda ETL`

## 2. 前提
- 現行構成
  - raw ログは S3 に `text + gzip` で保管済み
  - Glue Table `fw_log_analytics.fortigate_logs` で参照可能
  - Athena で検索可能
  - syslog サーバからの投入は `upload-fortigate-logs.sh + cron` で自動化済み
- 比較の前提条件
  - raw ログは残し、**別 prefix に Parquet を追加**する
  - 変換対象はまず `traffic` ログに限定する
  - 参考コストは **2GB / 回**の変換を前提とした概算である
  - 実料金はリージョン、処理時間、実装方式で変動する

## 3. 比較対象の概要

### 3.1 Athena CTAS / INSERT INTO
- 既存の raw テーブルを入力にして、Athena SQL で Parquet を生成する方式
- 初回作成は `CTAS`
- 日次追加は `INSERT INTO`
- 実行主体
  - 手動実行
  - EventBridge + Lambda
  - syslog サーバから `aws athena start-query-execution`

### 3.2 AWS Glue ETL Job
- Glue Job で raw ログを読み、Parquet を S3 に出力する方式
- 実装は PySpark を前提に考える
- 実行主体
  - Glue Trigger
  - EventBridge
  - 手動実行

### 3.3 AWS Lambda ETL
- Lambda 関数で raw ログを読み、Parquet を生成して S3 に出力する方式
- Python + Parquet ライブラリを前提に考える
- 実行主体
  - EventBridge
  - S3 Put イベント
  - 手動 Invoke

## 4. 比較表

| 観点 | 1. Athena CTAS / INSERT INTO | 2. AWS Glue ETL Job | 3. AWS Lambda ETL |
|---|---|---|---|
| 今の環境への影響度 | 低 | 中 | 中 |
| 実装難易度 | 低〜中 | 中〜高 | 中 |
| 学習難易度 | 低〜中 | 高 | 中 |
| ランニングコスト | 低 | 中 | 低〜中 |
| 運用コスト | 低 | 中 | 中 |
| 監視・再実行 | 仕組み追加が必要 | Glue Job 標準機能で扱いやすい | 自前実装が増えやすい |
| 複雑変換への強さ | 弱い | 強い | 中 |
| 大量バックフィルへの強さ | 中 | 強い | 弱い |
| 今回の PoC への向き | 最も高い | 高いがやや重い | 制約が多い |
| 本番拡張性 | 中 | 高 | 中 |

## 5. 各方式の詳細

### 5.1 Athena CTAS / INSERT INTO

#### 方式概要
- raw テーブル `fw_log_analytics.fortigate_logs` を参照し、Athena の SQL で Parquet を生成する。
- 例:
  - `CREATE TABLE AS SELECT ... WITH (format='PARQUET', partitioned_by=...)`
  - `INSERT INTO parquet_table SELECT ...`

#### 今の環境への影響
- **低い**
- 既存の raw テーブルをそのまま利用できる
- 追加が必要なのは次の程度
  - Parquet 用 S3 prefix
  - Parquet 用 Glue Table
  - 変換 SQL
  - 実行手順または実行トリガー

#### 実装難易度
- **低〜中**
- SQL ベースで実装できるため、Terraform 学習から自然に繋がりやすい
- ただし次は考慮が必要
  - 日次分だけ変換する SQL の設計
  - 失敗時の再実行手順
  - 同じ日付を二重投入しない運用

#### ランニングコスト
- **低い**
- Athena はスキャン量課金
- 2GB / 回なら概算 **約 $0.01 / 回**
- 小規模日次変換ではかなり扱いやすい

#### メリット
- 既存環境の変更が少ない
- まず PoC を作るのに最短
- Athena / SQL ベースで理解しやすい
- 追加サービスが少ない

#### デメリット
- 複雑な変換ロジックは SQL が読みづらくなりやすい
- 再処理や運用の作り込みは Glue より弱い
- 小さいファイルをまとめる制御はやりにくい

#### 向いているケース
- 最初の Parquet 化 PoC
- 変換対象が `traffic` ログ中心
- まず性能差とコスト差を見たい段階

### 5.2 AWS Glue ETL Job

#### 方式概要
- Glue Job で raw ログを読み込み、Parquet を S3 に出力する。
- 変換ロジックは PySpark で記述する。

#### 今の環境への影響
- **中**
- 次の追加が必要
  - Glue Job
  - Job 用 IAM
  - スケジュールまたはトリガー
  - Job script
  - Parquet 用 Glue Table

#### 実装難易度
- **中〜高**
- Spark の考え方と Glue Job の実行モデル理解が必要
- ただし次のような要求には対応しやすい
  - `action` 正規化
  - event / utm / vpn の分離
  - 小さいファイルの集約
  - 再処理

#### ランニングコスト
- **中**
- Glue ETL Job は DPU 時間課金
- 2GB / 回の Spark Job でも、最低コストは Athena より高くなりやすい
- 概算の目安
  - Spark ETL 最小実行: **約 $0.015 / 回以上**
  - 実時間が伸びると Athena より差が開きやすい

#### メリット
- 変換処理をコードとして明確に書ける
- 再処理やバックフィルに強い
- 本番運用へ拡張しやすい
- 複雑な変換に向く

#### デメリット
- 構成が一段重くなる
- 監視、失敗時対応、ジョブ管理が必要
- PoC としては実装コストが高い

#### 向いているケース
- 将来、正規化や多種ログ分離までやる
- 変換品質と保守性を重視する
- 本番寄りの運用を見据える

### 5.3 AWS Lambda ETL

#### 方式概要
- Lambda で S3 上の raw ログを読み、Parquet へ変換して別 prefix に保存する。
- Python で `pyarrow` などを使う想定。

#### 今の環境への影響
- **中**
- 次の追加が必要
  - Lambda 関数
  - Lambda 実行ロール
  - Layer または依存ライブラリ同梱
  - Trigger 設計
  - Parquet 用 Glue Table

#### 実装難易度
- **中**
- Athena よりは難しい
- Glue よりは構成は軽い
- ただし、2GB クラスだと次が制約になりやすい
  - メモリ
  - `/tmp` 容量
  - 15 分制限
  - ライブラリ管理

#### ランニングコスト
- **低〜中**
- 2GB / 回の変換が短時間で終わるなら安い
- 概算の目安
  - 数十秒〜数分なら **約 $0.002〜0.02 / 回**
- ただし処理時間に大きく依存する

#### メリット
- サーバレスで構成は比較的コンパクト
- 少量データなら低コスト
- EventBridge や S3 イベントと組み合わせやすい

#### デメリット
- 2GB 変換では制約に当たりやすい
- Parquet ライブラリ管理が面倒
- Glue Spark ほど複雑変換に向かない
- 失敗時のリトライや再処理を自前設計しやすい

#### 向いているケース
- 小規模データ
- 単純変換
- Glue ほど大きい構成にしたくない場合

## 6. ランニングコスト比較（2GB / 回の概算）

| 方式 | 概算費用/回 | 補足 |
|---|---:|---|
| Athena CTAS / INSERT INTO | 約 `$0.01` | スキャン量課金で見積もりやすい |
| AWS Glue ETL Job | 約 `$0.015` 以上 | Spark 前提では Athena より高くなりやすい |
| AWS Lambda ETL | 約 `$0.002〜0.02` | 実行時間・メモリ・一時領域に依存 |

**注意**
- 上記は S3 保存料金を含まない
- Glue は Job 実行時間次第で増える
- Lambda は処理時間次第で大きくぶれる
- 本番見積もりでは、日次回数と月間回数に直して確認する必要がある

## 7. 要件定義の観点で見る判断基準

### 7.1 Athena CTAS / INSERT INTO を選ぶ基準
- まずは Parquet 化の効果を確認したい
- 今の構成を大きく変えたくない
- 変換ロジックは単純でよい
- 学習しやすさを優先したい

### 7.2 AWS Glue ETL Job を選ぶ基準
- 変換処理を今後拡張したい
- 本番運用を見据えて再処理や監視を整えたい
- event / utm / vpn の分離や正規化も将来的にやりたい

### 7.3 AWS Lambda ETL を選ぶ基準
- データ量が小さく、単純変換で足りる
- Glue ほど重い構成にしたくない
- Lambda の制約内に収まることを確認済み

## 8. 推奨方針

### 要件定義段階の推奨
- **第一候補: Athena CTAS / INSERT INTO**
- **第二候補: AWS Glue ETL Job**
- **第三候補: AWS Lambda ETL**

### 理由
- 今の環境に最も載せやすいのは Athena
- 本番拡張性が最も高いのは Glue
- Lambda は費用面では魅力があるが、2GB クラスでは制約が先に来やすい

## 9. 結論
- **PoC / 学習 / 最短導入**を重視するなら `Athena CTAS / INSERT INTO`
- **本番拡張性 / 複雑変換 / 再処理性**を重視するなら `AWS Glue ETL Job`
- **Lambda は今回のサイズ条件では優先度を下げる**のが妥当

## 10. 次に整理すべき項目
1. Parquet 化の対象列
2. 出力 prefix 名
3. Parquet テーブル名
4. 日次実行か手動実行か
5. raw と Parquet のどちらを標準検索先にするか
6. DoD をどこに置くか
