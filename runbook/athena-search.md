# Athena Search Runbook

## 1. 目的
- FortiGate の traffic ログを Athena で再現性高く検索するための運用手順をまとめる。
- ログ投入後の確認、検索前チェック、一次切り分けを標準化する。
- SQL の具体例は [sql-templates.md](sql-templates.md) を参照し、この Runbook では運用フローと判断観点を定義する。

## 2. 対象と前提
- Glue Database: `fw_log_analytics`
- Glue Table: `fortigate_logs`
- Athena WorkGroup: `fw-log-analytics-wg`
- S3 配置先: `s3://<log-bucket>/fortigate/year=YYYY/month=MM/day=DD/*.log.gz`
- パーティション基準日: **JST**
- 対象ログ: **traffic ログ**
- event/system ログは検索対象外とし、collector 側で別ファイルに分離して保管する。

## 3. 運用の基本方針
- 検索前に **S3 配置、パーティション、件数** を確認する。
- いきなり詳細検索せず、まず `count(*)` で対象日付にデータがあるかを見る。
- 日付条件は必ず `year/month/day` を指定し、不要なフルスキャンを避ける。
- 標準検索は [sql-templates.md](sql-templates.md) のテンプレートを使う。
- 調査メモには、対象日付、検索条件、件数、使用した SQL を残す。

## 4. パーティション反映方針

### 4.1 推奨運用
- 推奨は **collector のアップロードスクリプトで Glue `batch-create-partition` を自動実行**する方式。
- 理由:
  - `ingest` ロールに Athena の SQL 実行権限を渡さずに済む。
  - S3 へアップロードした直後に、その日付パーティションだけを登録できる。
  - `ALTER TABLE` より責務分離が明確。

### 4.2 自動反映の前提
- `upload-fortigate-logs.sh` で `ENABLE_GLUE_PARTITION_ADD="true"` を設定する。

### 4.3 手動反映のフォールバック
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

## 5. 正常系の標準手順

### 5.1 S3 にログがあることを確認する
- 期待パス:
  - `fortigate/year=YYYY/month=MM/day=DD/`
- 確認観点:
  - 日付ディレクトリが正しいか
  - `.log.gz` ファイルが存在するか
  - traffic ログが格納されているか

### 5.2 パーティションが見えていることを確認する
```sql
SHOW PARTITIONS fw_log_analytics.fortigate_logs;
```

- 確認観点:
  - 対象の `year=YYYY/month=MM/day=DD` が表示されるか
  - 想定外の日付が混ざっていないか

### 5.3 件数を確認する
```sql
SELECT count(*) AS cnt
FROM fw_log_analytics.fortigate_logs
WHERE year = '2026'
  AND month = '03'
  AND day = '16';
```

- 確認観点:
  - 0 件ではないか
  - 想定件数とかけ離れていないか

### 5.4 標準 SQL で検索する
- `srcip` 検索
- `dstip` 検索
- `srcip OR dstip` 横断検索
- `action_raw` 絞り込み
- 期間指定検索

上記 SQL は [sql-templates.md](sql-templates.md) を使用する。

## 6. 検索前チェックリスト
- 対象日付は JST で整理できているか
- S3 パスは `fortigate/year=YYYY/month=MM/day=DD/` になっているか
- パーティションは自動登録済み、または手動追加済みか
- `count(*)` で件数を確認したか
- 検索条件の IP、期間、`action_raw` に誤りがないか
- Athena WorkGroup は `fw-log-analytics-wg` を使っているか

## 7. トラブル時の一次切り分け

### 7.1 症状: 0件
主な原因:
- S3 に対象ログが存在しない
- パーティション未登録
- 日付条件が JST とずれている
- `srcip` / `dstip` の指定ミス
- traffic ではなく event ログを検索しようとしている

確認手順:
1. S3 の対象パスにファイルがあるか確認する
2. `SHOW PARTITIONS` で対象日付が見えているか確認する
3. `count(*)` で日付単位の件数を確認する
4. IP 条件を外して対象日の一部データを確認する
5. `srcip` と `dstip` のどちらで検索すべきか見直す

対応:
- S3 にない場合は、collector からの投入手順を確認する
- パーティションがない場合は、自動登録のエラーログを確認し、必要なら `ALTER TABLE ... ADD IF NOT EXISTS PARTITION` を実行する
- JST/UTC 混在が疑われる場合は、対象日の切り方を見直す
- 条件が厳しすぎる場合は、まず片側条件だけで検索する

### 7.2 症状: AccessDenied
主な原因:
- Athena WorkGroup の利用権限不足
- Glue Database / Table の参照権限不足
- S3 のログバケット読み取り権限不足
- Athena 結果出力先 `athena-results/` への書き込み権限不足
- uploader 自動登録時は Glue `GetTable` または `BatchCreatePartition` の権限不足

確認手順:
1. どのサービスで拒否されたかエラーメッセージを確認する
2. WorkGroup 名が `fw-log-analytics-wg` になっているか確認する
3. Glue の `GetTable`、必要なら `BatchCreatePartition` が許可されているか確認する
4. S3 の `fortigate/` と `athena-results/` に必要権限があるか確認する

対応:
- 検索者ロールは Athena/Glue/S3 読み取り系に戻す
- `ingest` ロールは S3 投入と Glue パーティション追加だけに絞る
- 変更後は `SELECT count(*)` のような軽いクエリで再確認する

### 7.3 症状: HIVE_BAD_DATA
主な原因:
- ログ形式が Glue テーブルの regex と一致していない
- event/system ログが traffic 用パスに混入している
- gzip ファイルが破損している
- 文字列形式が想定と異なる

確認手順:
1. 問題の S3 オブジェクトを特定する
2. ローカルまたは syslog サーバで gzip 展開し、先頭数行を確認する
3. `type="traffic"` が入っているか確認する
4. `date=`, `time=`, `srcip=`, `dstip=` など必要項目が含まれているか確認する
5. event ログが混入していないか確認する

対応:
- traffic 以外が混ざっていれば collector の振り分け設定を見直す
- ログ形式が変わっていれば Glue regex の修正を検討する
- gzip 破損時は再投入する
- 影響範囲を限定するため、問題日のみ別パーティションで確認する

## 8. 追加の確認観点

### 8.1 検索結果の見方
- `log_date` / `log_time` が期待範囲か
- `srcip` / `dstip` が意図した向きか
- `action_raw` が `accept` / `deny` のどちらか
- `policyid` が期待ポリシーか

### 8.2 件数が多すぎる場合
- まず `count(*)` で件数を把握する
- `LIMIT` を付けて詳細確認する
- 期間を日単位に狭める
- `srcip` と `dstip` を片側ずつ確認する

### 8.3 Athena が遅い場合
- `ORDER BY` を外す
- まず `count(*)` または `LIMIT` 付き SQL で対象を絞る
- 日付条件をできるだけ狭める
- text + gzip + RegexSerDe は高速検索向きではないため、将来的な ETL/Parquet 化を検討する

## 9. 運用メモ
- 本 MVP は **低コスト保管と標準検索** を優先している。
- grep より高速であることを常に保証する設計ではない。
- 大量データの継続検索で性能が課題になった場合は、以下を将来案とする。
  - ファイル分割
  - ETL による Parquet 化
  - より低遅延な検索基盤の検討

## 10. Definition of Done
- ログ投入後の確認手順が記載されている
- パーティション自動登録の前提が記載されている
- 手動フォールバック手順が記載されている
- 検索前チェックリストがある
- `0件` の一次対応が記載されている
- `AccessDenied` の一次対応が記載されている
- `HIVE_BAD_DATA` の一次対応が記載されている
- SQL テンプレートへの参照がある
