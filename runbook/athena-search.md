# Athena Runbook（パーティション運用）

## 1. 目的
- `fw_log_analytics.fortigate_logs` の `year/month/day` パーティションを確実に反映し、検索漏れと不要スキャンを防ぐ。
- 本Runbookは Issue 13（パーティション運用手順）を対象とする。

## 2. 前提
- Glue Database: `fw_log_analytics`
- Glue Table: `fortigate_logs`
- S3ログ配置: `s3://<log-bucket>/fortigate/year=YYYY/month=MM/day=DD/*.log.gz`
- 日付基準: JST（Asia/Tokyo）
- Athena WorkGroup: `fw-log-analytics-wg`（運用標準）

## 3. 用語
- `MSCK REPAIR TABLE`: S3のパーティション形式パスを自動検出し、未登録パーティションを一括追加する。
- `ALTER TABLE ... ADD PARTITION`: 指定したパーティションだけを明示的に追加する。

## 4. 標準運用
### 4.1 初回同期（初回のみ）
```sql
MSCK REPAIR TABLE fw_log_analytics.fortigate_logs;
```

- 用途: 過去データを一括でカタログへ反映する。
- 実行タイミング: 初回構築時、または大量の過去ログを一括投入した直後。

### 4.2 日次運用（推奨）
```sql
ALTER TABLE fw_log_analytics.fortigate_logs
ADD IF NOT EXISTS
PARTITION (year='2026', month='03', day='05')
LOCATION 's3://<log-bucket>/fortigate/year=2026/month=03/day=05/';
```

- 用途: 当日分または指定日分だけを明示追加する。
- 実行タイミング: ログ投入完了後。
- 注意: `LOCATION` は必ずパーティション値と一致させる。

## 5. 反映確認
### 5.1 パーティション一覧確認
```sql
SHOW PARTITIONS fw_log_analytics.fortigate_logs;
```

### 5.2 対象日の件数確認
```sql
SELECT count(*) AS cnt
FROM fw_log_analytics.fortigate_logs
WHERE year='2026' AND month='03' AND day='05';
```

## 6. トラブルシュート
| 症状 | 主な原因 | 対応 |
|---|---|---|
| クエリ結果が0件 | パーティション未追加 | `ALTER TABLE ... ADD IF NOT EXISTS PARTITION` を実行 |
| クエリ結果が0件 | `LOCATION` と実パス不一致 | S3パスとSQLの `LOCATION` を一致させる |
| 追加後も0件 | 日付基準の不一致（JST/UTC） | パス設計がJST基準か確認し、条件を合わせる |
| `AccessDenied` | Athena/Glue/S3権限不足 | 実行ロールの権限を確認（Athena実行、Glue参照、S3参照） |
| 反映に時間がかかる | `MSCK` を広範囲で実行 | 日次は `ALTER TABLE` 運用へ切替える |

## 7. 運用チェックリスト（日次）
- ログが `fortigate/year=YYYY/month=MM/day=DD/` に投入済みである。
- `ALTER TABLE ... ADD IF NOT EXISTS PARTITION` を実行した。
- `SHOW PARTITIONS` で対象日が確認できる。
- 件数確認クエリでデータが参照できる。
