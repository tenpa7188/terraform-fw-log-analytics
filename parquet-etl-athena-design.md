# Athena 方式 Parquet 化 設計ドラフト

## 1. 目的
- 本文書は、[parquet-etl-athena-requirements.md](parquet-etl-athena-requirements.md) で確定した要件をもとに、Athena 方式による Parquet 化の設計を具体化するためのドラフトである。
- 本設計では、raw ログを残したまま、Athena を使って Parquet を生成し、検索性能を改善する構成を定義する。

## 2. 設計方針
- raw ログは原本として継続保管する
- Parquet は検索最適化用の派生データとして追加する
- 日次変換は **AWS 側スケジュール実行**とする
- 初回バックフィルは **1 年分を日単位の `INSERT INTO`** で実施する
- 再実行は **対象日を再生成**する
- 標準検索先は、性能確認後に raw から Parquet へ切り替える

## 3. 全体アーキテクチャ
```text
[FortiGate]
    |
    v
[syslogサーバ]
  - traffic ログを raw prefix へアップロード
  - Glue パーティション登録
    |
    v
[S3 raw]
  s3://<bucket>/fortigate/year=YYYY/month=MM/day=DD/*.log.gz
    |
    v
[Glue raw table]
  fw_log_analytics.fortigate_logs
    |
    v
[EventBridge Scheduler]
  - 日次で Lambda を起動
    |
    v
[Lambda: parquet-etl-runner]
  - 対象日を決定
  - 必要時は既存 Parquet を削除
  - Athena へ INSERT INTO を発行
  - 完了まで監視
    |
    v
[Athena WorkGroup]
  - fw-log-analytics-wg
  - 結果出力先は athena-results/
    |
    v
[S3 parquet]
  s3://<bucket>/fortigate-parquet/year=YYYY/month=MM/day=DD/
    |
    v
[Glue parquet table]
  fw_log_analytics.fortigate_logs_parquet
```

## 4. コンポーネント設計

### 4.1 既存コンポーネント
- S3 バケット
  - raw: `fortigate/`
  - Athena 結果: `athena-results/`
- Glue Database
  - `fw_log_analytics`
- Glue raw table
  - `fortigate_logs`
- Athena WorkGroup
  - `fw-log-analytics-wg`

### 4.2 追加コンポーネント
- S3 parquet prefix
  - `fortigate-parquet/`
- Glue parquet table
  - `fortigate_logs_parquet`
- Lambda
  - `parquet-etl-runner`
- EventBridge Scheduler
  - 日次実行スケジュール
- IAM
  - Lambda 実行ロール

## 5. S3 設計

### 5.1 raw
- 既存:
  - `s3://<bucket>/fortigate/year=YYYY/month=MM/day=DD/*.log.gz`
- 用途:
  - 原本保管
  - フォールバック検索
  - Parquet 変換元

### 5.2 Parquet
- 新設:
  - `s3://<bucket>/fortigate-parquet/year=YYYY/month=MM/day=DD/`
- 命名ルール:
  - Athena の `INSERT INTO` が出力するファイル名に任せる
- 用途:
  - 標準検索用

### 5.3 設計意図
- raw と Parquet を同一バケットに置くことで、権限・暗号化・タグ・運用ルールを揃えやすくする
- Prefix を分けることで、ライフサイクルや検索対象を今後分離しやすくする

## 6. Glue テーブル設計

### 6.1 raw テーブル
- テーブル名:
  - `fw_log_analytics.fortigate_logs`
- 用途:
  - 原本検索
  - Parquet 変換元

### 6.2 Parquet テーブル
- テーブル名:
  - `fw_log_analytics.fortigate_logs_parquet`
- データ形式:
  - `PARQUET`
- パーティション:
  - `year`, `month`, `day`
- ルートロケーション:
  - `s3://<bucket>/fortigate-parquet/`

### 6.3 Parquet テーブル列
- `log_date`
- `log_time`
- `srcip`
- `dstip`
- `srcport`
- `dstport`
- `proto`
- `action_raw`
- `policyid`
- `year`
- `month`
- `day`

### 6.4 `raw_line` を含めない理由
- 検索用途は構造化列中心で十分
- `raw_line` を含めるとサイズとスキャン量が増えやすい
- フォールバック検索は raw テーブルに残す

## 7. Athena SQL 設計

### 7.1 Parquet テーブル作成
- 方式:
  - Terraform で Glue Table を作成する
- Athena で CTAS によりテーブル本体を作るのではなく、**外部テーブルを Terraform 管理**する
- 理由:
  - テーブル定義をコード管理したい
  - Terraform で再現可能にしたい

### 7.2 日次変換 SQL
- 方式:
  - `INSERT INTO fw_log_analytics.fortigate_logs_parquet`
- 入力:
  - `fw_log_analytics.fortigate_logs`
- 条件:
  - 対象日を `year/month/day` で絞る

#### SQL テンプレート例
```sql
INSERT INTO fw_log_analytics.fortigate_logs_parquet
SELECT log_date,
       log_time,
       srcip,
       dstip,
       srcport,
       dstport,
       proto,
       action_raw,
       policyid,
       year,
       month,
       day
FROM fw_log_analytics.fortigate_logs
WHERE year = '2026'
  AND month = '03'
  AND day = '28';
```

### 7.3 設計上の注意
- partition 列 `year`, `month`, `day` は **SELECT の最後**に置く
- Athena `INSERT INTO` は最大 100 パーティション制限があるため、**1 日単位で実行**する
- 日次実行では 1 パーティションしか書かないため、制限に抵触しない  
Sources:
- [Use CTAS and INSERT INTO to work around the 100 partition limit](https://docs.aws.amazon.com/athena/latest/ug/ctas-insert-into.html)
- [INSERT INTO - Amazon Athena](https://docs.aws.amazon.com/athena/latest/ug/insert-into.html)

## 8. 日次実行設計

### 8.1 実行契機
- EventBridge Scheduler を使用する
- 例:
  - 毎日 `02:00 JST`

### 8.2 実行順序
1. Scheduler が Lambda を起動
2. Lambda が対象日を計算
   - 既定は「前日」
3. Lambda が対象日の raw データ有無を確認
4. Lambda が対象日の Parquet prefix を削除
5. Lambda が Athena `INSERT INTO` を実行
6. Lambda が Athena 完了状態を監視
7. 成功/失敗を CloudWatch Logs に記録

### 8.3 実行時刻の考え方
- syslog サーバ側の raw 投入と Glue パーティション登録が終わった後にする
- 推奨:
  - raw 投入と重ならない時刻に寄せる

### 8.4 設計意図
- syslog サーバに Athena 実行権限を持たせない
- 収集と変換を分離し、障害切り分けをしやすくする

## 9. 初回バックフィル設計

### 9.1 方針
- 1 年分を日単位で回す
- 1 日 = 1 回の `INSERT INTO`

### 9.2 実行方法
- 日次と同じ Lambda を使い、対象日を明示して順に実行する
- 実行主体:
  - 管理者が AWS CLI から Lambda を日付ごとに呼び出す
  - もしくは簡易バッチスクリプトを別途用意する

### 9.3 理由
- 失敗日を特定しやすい
- 再実行しやすい
- 日次運用と同じロジックを使える
- Athena のパーティション制限に安全

## 10. 再実行設計

### 10.1 方針
- 再実行は**対象日を再生成**する

### 10.2 手順
1. `fortigate-parquet/year=YYYY/month=MM/day=DD/` を削除
2. 同じ日付条件で `INSERT INTO` を再実行
3. 完了確認

### 10.3 設計意図
- append による重複を避ける
- 派生データは作り直せる前提にする
- raw を原本として残しているため、再生成が可能

## 11. Lambda 設計

### 11.1 役割
- 対象日決定
- 前提チェック
- Parquet prefix 削除
- Athena クエリ実行
- Athena 完了待ち
- ログ出力

### 11.2 入力
- `mode`
  - `daily`
  - `backfill`
  - `rebuild`
- `target_date`
  - `YYYY-MM-DD`

### 11.3 出力
- 実行結果
  - `SUCCEEDED`
  - `FAILED`
- 実行対象日
- Athena QueryExecutionId

### 11.4 失敗時の扱い
- Lambda を失敗終了にする
- CloudWatch Logs へ詳細を残す
- 必要に応じて再実行する

## 12. IAM 設計

### 12.1 Lambda 実行ロールに必要な権限
- Athena
  - `athena:StartQueryExecution`
  - `athena:GetQueryExecution`
  - `athena:StopQueryExecution`
  - `athena:GetWorkGroup`
- Glue
  - `glue:GetDatabase`
  - `glue:GetTable`
  - `glue:GetPartitions`
- S3
  - raw prefix の `GetObject` / `ListBucket`
  - parquet prefix の `PutObject` / `DeleteObject` / `ListBucket`
  - `athena-results/` の書き込み
- CloudWatch Logs
  - Lambda 標準出力

### 12.2 権限分離の考え方
- `ingest` ロールに Parquet 変換権限は持たせない
- 検索者ロールと ETL 実行ロールも分離する

## 13. 監視・運用設計

### 13.1 最低限の監視
- Lambda 実行失敗を検知できること
- Athena クエリ失敗理由を確認できること
- 当日分の Parquet データ有無を確認できること

### 13.2 運用確認項目
- 対象日付の raw データが存在する
- 対象日付の Parquet prefix が存在する
- `SHOW PARTITIONS fw_log_analytics.fortigate_logs_parquet;` で対象日が見える
- 標準検索 SQL が Parquet テーブルで実行できる

## 14. パフォーマンス確認設計

### 14.1 比較対象
- raw テーブル
  - `fw_log_analytics.fortigate_logs`
- Parquet テーブル
  - `fw_log_analytics.fortigate_logs_parquet`

### 14.2 比較観点
- `srcip`
- `dstip`
- `action`
- 期間指定

### 14.3 比較指標
- 実行時間
- スキャンしたデータ量

### 14.4 切替条件
- raw 比で**スキャン量減少**
- raw 比で**実行時間短縮**

## 15. Runbook 反映方針
- 標準検索:
  - Parquet テーブル優先
- フォールバック:
  - raw テーブル
- `HIVE_BAD_DATA` や抽出漏れ確認:
  - raw テーブルを利用

## 16. リスクと設計上の注意
- 1 日 1 回の `INSERT INTO` で Parquet ファイルが細かくなりすぎる可能性がある
- 日次実行時刻が早すぎると raw 投入完了前に走る可能性がある
- 再生成時に対象日を誤ると Parquet データを消すため、日付指定の安全策が必要
- Athena SQL を Lambda 文字列に埋め込む場合は保守性が落ちやすい
  - SQL テンプレートファイル化を検討する

## 17. 実装対象ファイルの見込み
- Terraform
  - `terraform/glue.tf`
  - `terraform/iam.tf`
  - `terraform/outputs.tf`
  - 必要に応じて `terraform/lambda.tf`, `terraform/scheduler.tf`
- Scripts
  - Athena 変換 SQL テンプレートまたは補助スクリプト
- Runbook
  - `runbook/athena-search.md`
  - `runbook/sql-templates.md`
- README
  - Parquet 標準検索方針の追記

## 18. 次の設計詳細化ポイント
1. Lambda 実装言語
2. Lambda から Athena へ渡す SQL の管理方式
3. 初回バックフィル実行用スクリプトの要否
4. Parquet prefix のライフサイクル方針
5. Parquet テーブルをいつ標準検索先へ切り替えるか
