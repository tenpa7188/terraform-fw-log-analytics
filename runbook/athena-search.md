# Athena Search Runbook

## 1. 目的
- FortiGate の traffic ログを Athena で再現性高く検索するための運用手順をまとめる。
- 標準検索は Parquet テーブル、障害時や抽出漏れ確認は raw テーブル、という使い分けを明確にする。
- syslogサーバからの raw 配置、ETL、Athena 検索までの判断手順を標準化する。
- SQL の具体例は [sql-templates.md](sql-templates.md) を参照し、この Runbook では運用フローと判断観点を定義する。

## 2. 対象と前提
- Glue Database: `fw_log_analytics`
- 標準検索テーブル: `fw_log_analytics.fortigate_logs_parquet`
- フォールバックテーブル: `fw_log_analytics.fortigate_logs`
- 標準検索 WorkGroup: `fw-log-analytics-wg`
- ETL 用 WorkGroup: `fw-log-analytics-etl-wg`
- raw 配置先: `s3://<log-bucket>/fortigate/year=YYYY/month=MM/day=DD/*.log.gz`
- Parquet 配置先: `s3://<log-bucket>/fortigate-parquet/year=YYYY/month=MM/day=DD/`
- パーティション基準日: **JST**
- 対象ログ: **traffic ログ**
- event/system ログは今回の Parquet 化対象外とし、syslogサーバ側で別ファイルに分離して保管する。
- この Runbook は Parquet 優先の標準運用を記載する。Parquet 未生成時や ETL 障害時は raw テーブルへ切り替える。

## 3. 構成の基本理解
- raw は原本であり、`fortigate/` 配下に継続保管する。
- Parquet は検索最適化用の派生データであり、`fortigate-parquet/` 配下に ETL で生成する。
- syslogサーバは raw アップロードと raw パーティション登録までを担う。
- EventBridge Scheduler が日次で Lambda `parquet-etl-runner` を起動し、raw から Parquet を生成する。
- 検索者は通常 `fw-log-analytics-wg` で Parquet テーブルを検索する。
- `HIVE_BAD_DATA`、抽出漏れ確認、`raw_line` 検索、ETL 障害時は raw テーブルを使う。

## 4. 運用の基本方針
- 検索前に **パーティション、件数、検索対象テーブル** を確認する。
- 標準検索は [sql-templates.md](sql-templates.md) の Parquet SQL を使う。
- いきなり詳細検索せず、まず `count(*)` で対象日付にデータがあるかを見る。
- 日付条件は必ず `year/month/day` を指定し、不要なフルスキャンを避ける。
- 調査メモには、対象日付、使用テーブル、検索条件、件数、使用した SQL を残す。
- ETL 障害時でも raw は残るため、検索手段を失わないことを前提に切り分ける。

## 5. パーティション反映方針

### 5.1 raw の反映方針
- 推奨は **syslogサーバのアップロードスクリプトで Glue `batch-create-partition` を自動実行**する方式。
- 理由:
  - `ingest` ロールに Athena SQL 実行権限を渡さずに済む。
  - S3 へアップロードした直後に、その日付パーティションだけを登録できる。
  - `ALTER TABLE` より責務分離が明確。

### 5.2 raw 自動反映の前提
- `upload-fortigate-logs.sh` で `ENABLE_GLUE_PARTITION_ADD="true"` を設定する。

### 5.3 raw 手動反映のフォールバック
- 自動反映が無効、または失敗時は `ALTER TABLE ... ADD IF NOT EXISTS PARTITION` で手動追加する。
- まとめて再検出したい場合のみ `MSCK REPAIR TABLE` を使う。
- 理由:
  - 手動時は対象日付を明示できる `ALTER TABLE` の方が安全。
  - `MSCK REPAIR TABLE` は広範囲を検出するため、日次運用の常用には向かない。

```sql
ALTER TABLE fw_log_analytics.fortigate_logs
ADD IF NOT EXISTS
PARTITION (year='2026', month='03', day='16')
LOCATION 's3://<log-bucket>/fortigate/year=2026/month=03/day=16/';
```

```sql
MSCK REPAIR TABLE fw_log_analytics.fortigate_logs;
```

### 5.4 Parquet の反映方針
- Parquet パーティションは日次 ETL または手動 backfill / rebuild で作成する。
- 通常運用では Parquet 側へ手動 `ALTER TABLE` を打たない。
- Parquet の有無は `SHOW PARTITIONS fw_log_analytics.fortigate_logs_parquet;` で確認する。
- raw が存在し、Parquet が未生成なら ETL 実行状況を確認する。

## 6. 正常系の標準手順

### 6.1 raw が S3 に存在することを確認する
- 期待パス:
  - `fortigate/year=YYYY/month=MM/day=DD/`
- 確認観点:
  - 日付ディレクトリが正しいか
  - `.log.gz` ファイルが存在するか
  - traffic ログが格納されているか

### 6.2 raw パーティションが見えていることを確認する
```sql
SHOW PARTITIONS fw_log_analytics.fortigate_logs;
```

- 確認観点:
  - 対象の `year=YYYY/month=MM/day=DD` が表示されるか
  - 想定外の日付が混ざっていないか

### 6.3 Parquet パーティションが見えていることを確認する
```sql
SHOW PARTITIONS fw_log_analytics.fortigate_logs_parquet;
```

- 確認観点:
  - 対象の `year=YYYY/month=MM/day=DD` が表示されるか
  - raw はあるのに Parquet が無い場合は ETL の遅延または失敗を疑う

### 6.4 Parquet 件数を確認する
```sql
SELECT count(*) AS cnt
FROM fw_log_analytics.fortigate_logs_parquet
WHERE year = '2026'
  AND month = '03'
  AND day = '16';
```

- 確認観点:
  - 0 件ではないか
  - 想定件数とかけ離れていないか

### 6.5 標準 SQL で検索する
- `srcip` 検索
- `dstip` 検索
- `srcip OR dstip` 横断検索
- `action_raw` 絞り込み
- 期間指定検索
- `srcip/dstip/期間/action` の複合検索

上記 SQL は [sql-templates.md](sql-templates.md) の Parquet テンプレートを使用する。

### 6.6 Parquet 未生成時は raw に切り替える
- Parquet パーティションが見えない場合は、まず raw テーブルで件数確認を行う。
- raw に件数があり Parquet が未生成なら、ETL を確認する。
- 調査を止めたくない場合は raw テーブルをフォールバック検索先として使う。

## 7. 手動 ETL 実行手順

### 7.1 backfill を実行する
- 何のために実行するか:
  - raw は存在するが Parquet が未作成の日を、日付指定で埋めるため。
- どこで実行するか:
  - リポジトリルート
- dry-run コマンド:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\invoke-parquet-backfill.ps1 `
  -StartDate 2026-03-16 `
  -EndDate 2026-03-16 `
  -DryRun
```

- 実行コマンド:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\invoke-parquet-backfill.ps1 `
  -StartDate 2026-03-16 `
  -EndDate 2026-03-16
```

- 品質サマリも確認したい場合:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\invoke-parquet-backfill.ps1 `
  -StartDate 2026-03-16 `
  -EndDate 2026-03-16 `
  -IncludeQualitySummary
```

- 成功条件:
  - dry-run では `{"mode":"backfill","target_date":"YYYY-MM-DD"}` の payload が表示される。
  - 本実行では Lambda の `Response body` 内で `status = SUCCEEDED` が返る。
  - 実行後に Parquet パーティションが見える。

### 7.2 rebuild を実行する
- 何のために実行するか:
  - 対象日の Parquet を削除し、raw から再生成するため。
- どこで実行するか:
  - リポジトリルート
- 注意:
  - rebuild は対象日の Parquet を削除してから再生成する。
  - dry-run で日付と payload を確認してから本実行する。
- dry-run コマンド:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\invoke-parquet-rebuild.ps1 `
  -TargetDate 2026-03-16 `
  -DryRun
```

- 実行コマンド:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\invoke-parquet-rebuild.ps1 `
  -TargetDate 2026-03-16
```

- 品質サマリも確認したい場合:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\invoke-parquet-rebuild.ps1 `
  -TargetDate 2026-03-16 `
  -IncludeQualitySummary
```

- 成功条件:
  - dry-run では `{"mode":"rebuild","target_date":"YYYY-MM-DD"}` の payload が表示される。
  - 本実行では Lambda の `Response body` 内で `status = SUCCEEDED` が返る。
  - 実行後に対象日の Parquet パーティションが再作成される。

## 8. 検索前チェックリスト
- 対象日付は JST で整理できているか
- 標準検索か、raw フォールバック検索かを決めたか
- Parquet を使う場合、`fortigate_logs_parquet` のパーティションは見えているか
- raw を使う場合、`fortigate_logs` のパーティションは見えているか
- `count(*)` で件数を確認したか
- 検索条件の IP、期間、`action_raw` に誤りがないか
- Athena WorkGroup は `fw-log-analytics-wg` を使っているか

## 9. トラブル時の一次切り分け

### 9.1 症状: Parquet で 0件またはパーティション未生成
主な原因:
- raw はあるが ETL がまだ走っていない
- EventBridge Scheduler が未実行または失敗
- Lambda `parquet-etl-runner` が失敗
- 対象日付の指定ミス

確認手順:
1. raw テーブルで対象日の `count(*)` を確認する
2. `SHOW PARTITIONS fw_log_analytics.fortigate_logs_parquet;` で対象日が見えるか確認する
3. Lambda `parquet-etl-runner` の CloudWatch Logs を確認する
4. 必要に応じて `invoke-parquet-backfill.ps1` を `-DryRun` で実行し、対象日 payload を確認する
5. 調査を優先する場合は raw テーブルへ切り替える

対応:
- raw にデータがあり Parquet が無い場合は backfill を実行する
- 対象日のみ再生成したい場合は rebuild を使う
- ETL 復旧までの間は raw テーブルをフォールバック検索先にする

### 9.2 症状: ETL Lambda 失敗
主な原因:
- Athena `StartQueryExecution` 権限不足
- Glue `CreatePartition` / `BatchCreatePartition` 権限不足
- Athena ETL 結果出力先への書き込み不可
- raw 不在
- SQL 実行失敗

確認手順:
1. CloudWatch Logs の `parquet-etl-runner` ログを確認する
2. `mode`, `target_date`, `quality_summary_enabled` を確認する
3. `quality_summary_query_execution_id` と `insert_query_execution_id` が出ていれば Athena 側の履歴を確認する
4. `fw-log-analytics-etl-wg` のクエリ履歴と結果出力先を確認する
5. raw が存在するかを `fortigate/year=YYYY/month=MM/day=DD/` で確認する

対応:
- 権限エラーは IAM を確認する
- raw 不在なら syslogサーバからのアップロード完了時刻を確認する
- 失敗日のみ backfill または rebuild で再実行する
- 復旧までの検索は raw テーブルへ切り替える

### 9.3 症状: AccessDenied
主な原因:
- 標準検索 WorkGroup の利用権限不足
- Glue Database / Table の参照権限不足
- S3 のログバケット読み取り権限不足
- Athena 結果出力先 `athena-results/` への書き込み権限不足
- ETL 実行時は `athena-results/etl/`、Glue Parquet テーブル、Parquet prefix への権限不足

確認手順:
1. どのサービスで拒否されたかエラーメッセージを確認する
2. 検索時は `fw-log-analytics-wg`、ETL 時は `fw-log-analytics-etl-wg` が使われているか確認する
3. Glue の対象テーブルが raw か Parquet か確認する
4. S3 の `fortigate/`、`fortigate-parquet/`、`athena-results/` への必要権限を確認する

対応:
- 検索者ロールは Athena/Glue/S3 読み取り系に戻す
- ETL 実行ロールは ETL 用 WorkGroup と Parquet 書き込み系に絞る
- 権限変更後は `count(*)` の軽いクエリまたは 1 日分 backfill で再確認する

### 9.4 症状: HIVE_BAD_DATA または抽出漏れ確認が必要
主な原因:
- raw ログ形式が Glue テーブルの regex と一致していない
- event/system ログが traffic 用パスに混入している
- gzip ファイルが破損している
- `raw_line` を見ないと原因が追えない

確認手順:
1. 問題の S3 オブジェクトを特定する
2. raw テーブルで対象日の件数を確認する
3. [sql-templates.md](sql-templates.md) の raw フォールバック SQL で `raw_line` を確認する
4. `type="traffic"` が入っているか確認する
5. event ログが混入していないか確認する

対応:
- 抽出漏れ確認や `raw_line` 検索は raw テーブルを使う
- traffic 以外が混ざっていれば syslogサーバ側の振り分け設定を見直す
- ログ形式が変わっていれば Glue regex の修正を検討する
- gzip 破損時は再投入する

### 9.5 症状: 検索が遅い
主な原因:
- 日付条件が広すぎる
- `ORDER BY` や不要列が多い
- raw テーブルを標準検索に使っている
- Parquet が未生成で raw フォールバックになっている

確認手順:
1. 使用テーブルが Parquet か raw か確認する
2. `count(*)` で対象範囲を確認する
3. `ORDER BY` や `LIMIT` の有無を見直す
4. Parquet パーティションがあるのに raw を使っていないか確認する

対応:
- 標準検索は Parquet テーブルへ寄せる
- まず日単位で確認し、必要なら期間を広げる
- ETL 未完了なら backfill 実行後に再検索する

## 10. 運用メモ
- raw は原本、Parquet は検索最適化用の派生データとして扱う。
- `raw_line` は Parquet テーブルに含めないため、標準検索外の調査は raw テーブル依存になる。
- `fw-log-analytics-etl-wg` は ETL 専用であり、利用者の通常検索には使わない。
- ETL の品質サマリは既定では無効であり、必要時のみ PowerShell スクリプトの `-IncludeQualitySummary` を付けて確認する。

## 11. Definition of Done
- 標準検索が Parquet、フォールバックが raw で整理されている
- raw / Parquet の確認手順が記載されている
- backfill / rebuild の手動起動手順が記載されている
- ETL 失敗時の一次切り分けが記載されている
- SQL テンプレートへの参照がある
