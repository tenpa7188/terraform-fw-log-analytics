# SQL Templates

## 1. 目的
- Athena での FW ログ検索手順を標準化する。
- 標準検索は Parquet テーブル、障害時や抽出漏れ確認は raw テーブル、という使い分けを明確にする。
- `srcip` / `dstip` / 期間 / `action` を中心に、運用者がコピペで検索できるようにする。
- パーティション条件を明示し、不要な全件走査を避けてコストを抑える。

## 2. 前提
- Glue Database: `fw_log_analytics`
- 標準検索テーブル: `fw_log_analytics.fortigate_logs_parquet`
- フォールバックテーブル: `fw_log_analytics.fortigate_logs`
- 標準検索 WorkGroup: `fw-log-analytics-wg`
- ETL 用 WorkGroup: `fw-log-analytics-etl-wg`
- パーティション列: `year`, `month`, `day`
- **日付パーティションは JST 前提**
- `month` と `day` は `03`、`05` のようにゼロ埋め文字列で指定する。
- Parquet テーブルの主な列:
  - `log_date`: `string`
  - `log_time`: `string`
  - `srcip`: `string`
  - `dstip`: `string`
  - `srcport`: `int`
  - `dstport`: `int`
  - `proto`: `int`
  - `action_raw`: `string`
  - `policyid`: `int`
- raw テーブルは `raw_line` を持つが、Parquet テーブルは `raw_line` を持たない。
- `HIVE_BAD_DATA`、抽出漏れ確認、`raw_line` 検索が必要な場合は raw テーブルを使う。

## 3. 使い方

- `<YEAR>`、`<MONTH>`、`<DAY>` などのプレースホルダを実値に置き換えて実行する。
- **まず件数確認 SQL を実行し、その後に詳細確認 SQL を実行する。**
- 期間が広い場合も、可能な限りパーティション条件を絞る。
- raw テーブルで構造化列検索をしたい場合は、標準 SQL のテーブル名だけ `fw_log_analytics.fortigate_logs` に置き換えてよい。

### 3.1 プレースホルダ
- `<YEAR>`: 4桁年。例: `2026`
- `<MONTH>`: 2桁月。例: `03`
- `<DAY>`: 2桁日。例: `05`
- `<SRCIP>`: 送信元 IP。例: `192.0.2.10`
- `<DSTIP>`: 宛先 IP。例: `198.51.100.20`
- `<IP>`: 送受信どちらでも検索したい IP。例: `192.0.2.10`
- `<ACTION>`: アクション。例: `accept`, `deny`
- `<LIMIT>`: 表示件数。例: `100`
- `<KEYWORD>`: raw_line で探したい文字列
- `<REGEX>`: raw_line で探したい正規表現

## 4. 標準 SQL テンプレート: Parquet 優先

### 4.1 件数確認
```sql
SELECT count(*) AS cnt
FROM fw_log_analytics.fortigate_logs_parquet
WHERE year = '<YEAR>'
  AND month = '<MONTH>'
  AND day = '<DAY>';
```

- 用途: Parquet 側の対象日件数確認
- 意図: 詳細検索前に、Parquet パーティションが正しく参照できているかを確認する

### 4.2 srcip 指定検索
```sql
SELECT log_date,
       log_time,
       srcip,
       dstip,
       srcport,
       dstport,
       proto,
       action_raw,
       policyid
FROM fw_log_analytics.fortigate_logs_parquet
WHERE year = '<YEAR>'
  AND month = '<MONTH>'
  AND day = '<DAY>'
  AND srcip = '<SRCIP>'
ORDER BY log_date, log_time
LIMIT <LIMIT>;
```

- 用途: 特定送信元 IP の通信履歴確認
- 意図: 最も頻度が高い検索を標準化する

### 4.3 dstip 指定検索
```sql
SELECT log_date,
       log_time,
       srcip,
       dstip,
       srcport,
       dstport,
       proto,
       action_raw,
       policyid
FROM fw_log_analytics.fortigate_logs_parquet
WHERE year = '<YEAR>'
  AND month = '<MONTH>'
  AND day = '<DAY>'
  AND dstip = '<DSTIP>'
ORDER BY log_date, log_time
LIMIT <LIMIT>;
```

- 用途: 特定宛先 IP の通信履歴確認
- 意図: `srcip` と対になる標準テンプレートとして用意する

### 4.4 srcip / dstip 横断検索
```sql
SELECT log_date,
       log_time,
       srcip,
       dstip,
       srcport,
       dstport,
       proto,
       action_raw,
       policyid
FROM fw_log_analytics.fortigate_logs_parquet
WHERE year = '<YEAR>'
  AND month = '<MONTH>'
  AND day = '<DAY>'
  AND (srcip = '<IP>' OR dstip = '<IP>')
ORDER BY log_date, log_time
LIMIT <LIMIT>;
```

- 用途: 1つの IP を軸に送受信の両方を追跡する
- 意図: インシデント調査時の初動を早くする

### 4.5 action 絞り込み検索
```sql
SELECT log_date,
       log_time,
       srcip,
       dstip,
       proto,
       action_raw,
       policyid
FROM fw_log_analytics.fortigate_logs_parquet
WHERE year = '<YEAR>'
  AND month = '<MONTH>'
  AND day = '<DAY>'
  AND lower(action_raw) = lower('<ACTION>')
ORDER BY log_date, log_time
LIMIT <LIMIT>;
```

- 用途: `accept` / `deny` のみを抽出する
- 意図: 表記ゆれに備えて `lower()` で比較する

### 4.6 srcip + action 絞り込み検索
```sql
SELECT log_date,
       log_time,
       srcip,
       dstip,
       srcport,
       dstport,
       proto,
       action_raw,
       policyid
FROM fw_log_analytics.fortigate_logs_parquet
WHERE year = '<YEAR>'
  AND month = '<MONTH>'
  AND day = '<DAY>'
  AND srcip = '<SRCIP>'
  AND lower(action_raw) = lower('<ACTION>')
ORDER BY log_date, log_time
LIMIT <LIMIT>;
```

- 用途: 特定送信元 IP の許可通信または拒否通信を確認する
- 意図: 調査対象 IP のノイズを減らす

### 4.7 期間指定検索
```sql
SELECT year,
       month,
       day,
       log_date,
       log_time,
       srcip,
       dstip,
       proto,
       action_raw,
       policyid
FROM fw_log_analytics.fortigate_logs_parquet
WHERE (
        (year = '2026' AND month = '03' AND day BETWEEN '01' AND '09')
     OR (year = '2026' AND month = '03' AND day BETWEEN '10' AND '19')
      )
  AND srcip = '<SRCIP>'
ORDER BY year, month, day, log_date, log_time
LIMIT <LIMIT>;
```

- 用途: 複数日の通信を追跡する
- 意図: パーティション条件を入れたまま期間検索する
- 注意: 月またぎ・年またぎは `OR` 条件を明示して追加する

### 4.8 srcip/dstip/期間/action の複合検索
```sql
SELECT year,
       month,
       day,
       log_date,
       log_time,
       srcip,
       dstip,
       srcport,
       dstport,
       proto,
       action_raw,
       policyid
FROM fw_log_analytics.fortigate_logs_parquet
WHERE (
        (year = '2026' AND month = '03' AND day BETWEEN '01' AND '09')
     OR (year = '2026' AND month = '03' AND day BETWEEN '10' AND '19')
      )
  AND (srcip = '<IP>' OR dstip = '<IP>')
  AND lower(action_raw) = lower('<ACTION>')
ORDER BY year, month, day, log_date, log_time
LIMIT <LIMIT>;
```

- 用途: IP、期間、action をまとめて絞りたい場合
- 意図: 実運用で多い複合条件をコピペで使えるようにする

### 4.9 deny の多い通信先確認
```sql
SELECT dstip,
       count(*) AS deny_count
FROM fw_log_analytics.fortigate_logs_parquet
WHERE year = '<YEAR>'
  AND month = '<MONTH>'
  AND day = '<DAY>'
  AND lower(action_raw) = 'deny'
GROUP BY dstip
ORDER BY deny_count DESC
LIMIT 20;
```

- 用途: 拒否の多い宛先を俯瞰する
- 意図: 傾向把握や異常検知の初期確認に使う

## 5. raw フォールバック SQL

### 5.1 構造化列のフォールバック検索
- `srcip`、`dstip`、`action_raw`、期間検索などの構造化列検索は、4章の SQL のテーブル名だけを次のように置き換えて使う。

```text
fw_log_analytics.fortigate_logs_parquet
→ fw_log_analytics.fortigate_logs
```

- 補足:
  - raw テーブルでは `srcport`、`dstport`、`proto`、`policyid` は文字列として返る。
  - IP や `action_raw` を軸に見る標準調査では、そのままでも実用上問題ない。

### 5.2 生ログ文字列検索
```sql
SELECT raw_line
FROM fw_log_analytics.fortigate_logs
WHERE year = '<YEAR>'
  AND month = '<MONTH>'
  AND day = '<DAY>'
  AND raw_line LIKE '%<KEYWORD>%'
LIMIT <LIMIT>;
```

- 用途: 抽出列にない項目を探したい場合
- 意図: RegexSerDe で取り出していないフィールドも一時的に確認できる
- 注意: `LIKE` は列検索より非効率なので、まず日付条件を絞る

### 5.3 正規表現検索
```sql
SELECT raw_line
FROM fw_log_analytics.fortigate_logs
WHERE year = '<YEAR>'
  AND month = '<MONTH>'
  AND day = '<DAY>'
  AND regexp_like(raw_line, '<REGEX>')
LIMIT <LIMIT>;
```

- 用途: `policyid=1001` のような key=value を柔軟に探す
- 意図: `LIKE` では表現しにくい条件を補う
- 注意: 正規表現は誤記しやすいため、まず `LIKE` で代替できるか検討する

## 6. 実行時の注意
- **パーティション条件なしの検索は標準手順にしない。**
- まず `count(*)` で対象日の件数を確認してから詳細検索に進む。
- 標準検索は Parquet テーブル、raw はフォールバックとして使う。
- `LIMIT` は初回確認では `100` 程度を推奨する。
- 月またぎ・年またぎの検索は、対象日を明示的に `OR` で分ける。
- `raw_line` が必要になった時点で raw テーブルへ切り替える。

## 7. 動作確認用サンプル
- サンプル配置先:
  - `samples/fortigate/year=2026/month=03/day=05/sample.log.gz`
- サンプルで使える代表値:
  - `srcip = '192.0.2.10'`
  - `dstip = '198.51.100.20'`
  - `action_raw = 'deny'`

### 7.1 Parquet サンプル確認 SQL
```sql
SELECT log_date,
       log_time,
       srcip,
       dstip,
       action_raw
FROM fw_log_analytics.fortigate_logs_parquet
WHERE year = '2026'
  AND month = '03'
  AND day = '05'
  AND srcip = '192.0.2.10'
ORDER BY log_date, log_time
LIMIT 100;
```

- 期待値: 3件ヒット

```sql
SELECT log_date,
       log_time,
       srcip,
       dstip,
       action_raw
FROM fw_log_analytics.fortigate_logs_parquet
WHERE year = '2026'
  AND month = '03'
  AND day = '05'
  AND dstip = '198.51.100.20'
ORDER BY log_date, log_time
LIMIT 100;
```

- 期待値: 3件ヒット

```sql
SELECT count(*) AS deny_count
FROM fw_log_analytics.fortigate_logs_parquet
WHERE year = '2026'
  AND month = '03'
  AND day = '05'
  AND lower(action_raw) = 'deny';
```

- 期待値: 4件ヒット

### 7.2 raw フォールバック時の考え方
- Parquet で結果が出ず raw に切り替える場合は、上記 SQL のテーブル名を `fw_log_analytics.fortigate_logs` に置き換える。
- `raw_line` を確認したい場合は 5.2 または 5.3 を使う。
