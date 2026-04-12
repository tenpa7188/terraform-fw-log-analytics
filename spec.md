# terraform-fw-log-analytics 仕様書（spec.md）

## 1) 目的・背景
本リポジトリ `terraform-fw-log-analytics` の目的は、FortiGate 想定の FW ログを低コストかつ安全に保管し、Athena で IP 検索を標準化することです。

- 現状課題
  - syslog サーバ上で 1 年分の FW ログを `grep` などで検索しており、対象ログ量が多いと検索完了まで時間がかかる
  - `grep`、一部ログ抽出、正規表現の使い方が担当者ごとに異なり、検索手順が属人化している
- 解決方針
  - AWS 側は `S3 + Glue Data Catalog + Athena + IAM` を Terraform で再現可能に構築する
  - syslog サーバ側は rsyslog 設定、S3 アップロードスクリプト、cron 設定例をリポジトリで管理する
- 目標
  - **検索手順標準化**: SQL テンプレートと Runbook を提供する
  - **安全運用**: 公開防止、暗号化、誤削除対策、最小権限を明確にする
  - **再現性確保**: ローカルから `terraform apply` でき、サンプルログで動作確認できる

**仮定**

- AWS アカウントは 1 つ、初期は `dev` 環境で検証し、将来 `stg/prod` に展開する
- FortiGate ログは `key=value` の 1 行 1 イベント（syslog 風テキスト）として S3 に投入する
- ログは `.log.gz` 形式で保管する
- パーティション日付は `date` フィールドを採用し、基準タイムゾーンは JST（Asia/Tokyo）で統一する
- 保管期間は既定で 365 日とし、要件変更時に最大 1825 日まで延長できる設計とする
- 暗号化は検証環境で SSE-S3、本番環境で SSE-KMS を使用する
- 想定ログ量は 0.5-2GB/日（生ログ）、Athena 同時実行は最大 10 クエリを前提とする
- syslog サーバ上のアップロードはスクリプト + cron で自動化し、Glue パーティション登録も同スクリプトで行う

## 2) 用語定義
| 用語 | 定義 |
|---|---|
| S3 Prefix | バケット内の論理パス。`fortigate/year=YYYY/month=MM/day=DD/` を採用 |
| Partition | Athena のスキャン対象を絞るための分割キー（`year/month/day`） |
| Glue Data Catalog | Athena が参照するメタデータ（DB/テーブル定義） |
| WorkGroup | Athena の実行単位。出力先やスキャン上限を強制できる |
| 最小権限 | 必要最小限の操作のみ許可する IAM 設計方針 |
| 生ログ検索 | `raw_line` 文字列に対して `LIKE` や `regexp_like` を使う検索方法 |
| syslog サーバ | FortiGate から syslog を受信し、traffic ログを S3 へアップロードする Linux サーバ |

## 3) 全体アーキテクチャ（テキスト図）
```text
[FortiGate]
    |
    | syslog (traffic/event)
    v
[syslogサーバ]
  - rsyslog で受信
  - traffic を incoming.log に保存
  - event を event.log に分離
  - cron で upload-fortigate-logs.sh を日次実行
  - traffic ログを S3 へアップロード
  - Glue batch-create-partition で日付パーティション登録
    |
    v
[S3: fw-log-analytics-<env>-<random>]
  - fortigate/year=YYYY/month=MM/day=DD/*.log.gz
  - athena-results/
    |
    v
[Glue Data Catalog]
  DB: fw_log_analytics
  Table: fortigate_logs
    |
    v
[Athena WorkGroup: fw-log-analytics-wg]
  - 強制出力先: s3://.../athena-results/
  - スキャン上限: 変数化（既定 20GB/クエリ）
    |
    v
[利用者]
  - Runbook と SQL テンプレートで srcip / dstip / 期間 / action を検索
```

**設計意図**
- AWS 側はマネージドサービス中心で構成し、再現性と運用容易性を優先する
- syslog サーバ側は最小限の補助スクリプトに留め、収集処理と AWS 側検索基盤を分離する
- event ログは検索対象から外し、traffic ログに絞って MVP の複雑さを抑える

## 4) スコープ
### 現在のスコープ
- Terraform で以下を作成する
  - S3（ログ保管、Athena 結果出力先）
  - Glue Data Catalog（DB/テーブル）
  - Athena WorkGroup（出力先強制、スキャン上限）
  - IAM（`ingest` / `analyst` / `terraform` ロール、必要に応じて `ingest` 専用 IAM ユーザー）
- 日付パーティション前提の S3 パス設計
- Athena での IP 検索を前提とした SQL テンプレート整備
- README / Runbook による検索手順と切り分け手順の標準化
- syslog サーバ向け補助ファイルの提供
  - rsyslog 設定
  - S3 アップロードスクリプト
  - cron 設定例

### 現在はスコープ外
- Parquet 変換や ETL 最適化
- GUI 検索画面
- Terraform modules 化
- AWS 上の収集インフラそのものを Terraform で構築すること

## 5) 機能要件（S3/Glue/Athena/IAM）
| コンポーネント | 要件 | 設計意図 |
|---|---|---|
| S3 | バケット名は `fw-log-analytics-<env>-<random>` | 命名一貫性とグローバル重複回避 |
| S3 | Public Access Block を全有効化 | 誤公開防止 |
| S3 | バケットデフォルト暗号化を有効化（検証: SSE-S3 / 本番: SSE-KMS） | 環境ごとの統制要件に合わせる |
| S3 | Versioning を有効化 | 誤削除・上書き対策 |
| S3 | TLS 強制のバケットポリシーを設定 | 平文通信を拒否する |
| S3 | Lifecycle を設定する | 保管コスト最適化 |
| Glue | DB 名は `fw_log_analytics` | 固定命名で運用手順を統一 |
| Glue | テーブル名は `fortigate_logs` | 固定命名で SQL テンプレート互換性を維持 |
| Athena | WorkGroup 名は `fw-log-analytics-wg` | チーム標準実行経路を固定する |
| Athena | 出力先を `s3://<bucket>/athena-results/` に固定する | 結果散逸防止と監査容易化 |
| IAM | ログ投入、検索、Terraform 実行の権限を分離する | 誤操作影響を局所化する |
| IAM | `ingest` ロールは `fortigate/` への書き込みと Glue パーティション登録のみを許可する | Athena 実行権限を持たせず責務を絞る |
| IAM | `analyst` ロールは Athena/Glue 参照、`fortigate/` 読み取り、`athena-results/` 読み書きを許可する | 検索運用に必要な権限だけを渡す |
| IAM | `terraform` ロールは本プロジェクト関連リソースの管理権限を持つ | Terraform 実行者の責務を明確化する |

## 6) データ設計（S3パス設計、partition設計、命名）
### S3 パス設計
- traffic ログ保存先
  - `s3://fw-log-analytics-<env>-<random>/fortigate/year=YYYY/month=MM/day=DD/fortigate-YYYYMMDD.log.gz`
- Athena 結果
  - `s3://fw-log-analytics-<env>-<random>/athena-results/`

### パーティション設計
- パーティションキー: `year`, `month`, `day`
- 形式: `year=2026/month=03/day=16`
- `month` と `day` はゼロ埋め 2 桁文字列とする
- 基準日: **イベント発生日**（`date` フィールド）
- 基準タイムゾーン: **JST（Asia/Tokyo）**
- 検索ルール: クエリ時は原則 `year/month/day` を条件に含める

### ログ行の想定形式
```text
date=2026-03-16 time=05:31:58 devname="FG..." type="traffic" srcip=192.168.1.101 srcport=40485 dstip=61.205.120.130 dstport=123 proto=17 action="accept" policyid=1 ...
```

### 抽出対象フィールド
- `raw_line`
- `log_date`
- `log_time`
- `srcip`
- `dstip`
- `srcport`
- `dstport`
- `proto`
- `action_raw`
- `policyid`

**補足**
- `action_norm` は現行実装では保持しない
- event/system ログは `event.log` へ分離し、`fortigate/` プレフィックスには置かない

**設計意図**
- よく使う検索軸（IP、期間、action、policyid）だけをテーブル列に持たせ、残りは `raw_line` をフォールバックにする

## 7) Athenaテーブル設計方針（最低1案＋代替案）
### 案A（採用）: RegexSerDe による構造化テーブル + `raw_line`
- テーブル: `fw_log_analytics.fortigate_logs`
- 方針:
  - `RegexSerDe` で必要フィールドを抽出する
  - 同時に `raw_line` を保持する
  - `date/time/srcip/dstip` は行内の位置が固定でなくても抽出できるよう lookahead ベースで定義する
  - `action="accept"` のような引用符付き値にも対応する
- 利点:
  - SQL 可読性が高い
  - 運用者間で検索軸を統一しやすい
  - `raw_line` によるフォールバック検索ができる
- 注意:
  - `srcip` / `dstip` を持たない event ログは対象外
  - text + gzip + RegexSerDe のため、検索性能は高速化の余地がある

### 案B（代替）: 生ログ中心テーブル
- 方針:
  - `raw_line` 主体で保持し、`regexp_extract` をクエリ側で使う
- 利点:
  - ログ書式変化に強い
- 欠点:
  - SQL が複雑になり、属人化しやすい

### 採用判断
- 現状は案Aを採用する
- 速度・コスト課題が顕在化した場合は、将来拡張として ETL / Parquet 化を検討する

## 8) 検索仕様（IP検索を中心にSQLテンプレを複数）
**共通ルール**

- WorkGroup は `fw-log-analytics-wg` を使用する
- 初回は `LIMIT` を付けて対象確認後に範囲を広げる
- 原則として `year/month/day` 条件を含める

### テンプレート1: srcip 検索
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
FROM fw_log_analytics.fortigate_logs
WHERE year = '2026'
  AND month = '03'
  AND day = '05'
  AND srcip = '192.0.2.10'
ORDER BY log_date, log_time
LIMIT 100;
```

### テンプレート2: dstip 検索
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
FROM fw_log_analytics.fortigate_logs
WHERE year = '2026'
  AND month = '03'
  AND day = '05'
  AND dstip = '198.51.100.20'
ORDER BY log_date, log_time
LIMIT 100;
```

### テンプレート3: srcip / dstip 横断検索
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
FROM fw_log_analytics.fortigate_logs
WHERE year = '2026'
  AND month = '03'
  AND day = '05'
  AND (srcip = '192.0.2.10' OR dstip = '192.0.2.10')
ORDER BY log_date, log_time
LIMIT 100;
```

### テンプレート4: action 絞り込み
```sql
SELECT log_date,
       log_time,
       srcip,
       dstip,
       proto,
       action_raw,
       policyid
FROM fw_log_analytics.fortigate_logs
WHERE year = '2026'
  AND month = '03'
  AND day = '05'
  AND lower(action_raw) = 'deny'
ORDER BY log_date, log_time
LIMIT 100;
```

### テンプレート5: 期間指定検索
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
FROM fw_log_analytics.fortigate_logs
WHERE (
        (year = '2026' AND month = '03' AND day BETWEEN '01' AND '09')
     OR (year = '2026' AND month = '03' AND day BETWEEN '10' AND '19')
      )
  AND srcip = '192.0.2.10'
ORDER BY year, month, day, log_date, log_time
LIMIT 100;
```

### テンプレート6: 生ログフォールバック検索
```sql
SELECT raw_line
FROM fw_log_analytics.fortigate_logs
WHERE year = '2026'
  AND month = '03'
  AND day = '05'
  AND regexp_like(raw_line, '(^| )srcip=192\\.0\\.2\\.10( |$)|(^| )dstip=192\\.0\\.2\\.10( |$)')
LIMIT 100;
```

## 9) セキュリティ設計（最小権限の考え方、公開禁止、暗号化）
- S3 Public Access Block を全有効化し、公開設定を防止する
- バケットデフォルト暗号化を有効化する
  - `dev`: SSE-S3（`AES256`）
  - `prod`: SSE-KMS（`alias/aws/s3`）
- バケットポリシーで `aws:SecureTransport = false` を拒否し、TLS を強制する
- `BucketOwnerEnforced` を設定し、ACL ベース運用を避ける
- Versioning を有効化し、誤削除・上書き時の復旧余地を持たせる
- IAM は責務で分離する
  - `ingest` ロール
    - `fortigate/` への `PutObject`
    - `ListBucket`
    - `glue:GetTable`
    - `glue:BatchCreatePartition`
  - `analyst` ロール
    - Athena WorkGroup 利用
    - Glue 参照
    - `fortigate/` の `GetObject`
    - `athena-results/` の `GetObject` / `PutObject` / `DeleteObject`
  - `terraform` ロール
    - 本プロジェクト関連の S3 / Glue / Athena / IAM 管理
- 必要時のみ `ingest` 専用 IAM ユーザーを作成し、権限は `sts:AssumeRole` のみに限定する

**設計意図**
- 検索者と投入者の責務を分け、Athena 実行権限を投入者に持たせない
- AWS 外ホストからの接続も、長期権限を最小化した形で扱う

## 10) 運用設計（ログ投入、検索の標準手順、トラブル時の切り分け）
### 標準手順（構築）
```bash
cd terraform
terraform init
terraform validate
terraform plan -var-file=envs/dev.tfvars
terraform apply -var-file=envs/dev.tfvars
```

### 標準手順（syslog サーバ側）
- rsyslog で FortiGate の syslog を受信する
- traffic ログを `incoming.log` に保存する
- event ログを `event.log` に分離する
- cron で `upload-fortigate-logs.sh` を日次実行する
- `upload-fortigate-logs.sh` は以下を行う
  - `incoming.log-YYYYMMDD.gz` を S3 へアップロード
  - 必要に応じて Glue `batch-create-partition` で日付パーティションを登録

### 標準手順（検索）
- Athena WorkGroup `fw-log-analytics-wg` を使用する
- まず `count(*)` で件数確認する
- 標準 SQL は `runbook/sql-templates.md` を使う
- 調査メモには対象日、IP、件数、SQL を残す

### 手動フォールバック
- 自動パーティション登録が失敗した場合は `ALTER TABLE ... ADD IF NOT EXISTS PARTITION` を使う
- 広範囲再検出が必要な場合のみ `MSCK REPAIR TABLE` を使う

### トラブル切り分け
| 症状 | 主な原因 | 一次対応 |
|---|---|---|
| Athena 結果が 0 件 | S3 配置ミス、パーティション未登録、JST 日付条件ミス、IP 指定ミス | S3 パス、`SHOW PARTITIONS`、`count(*)` を確認する |
| AccessDenied | IAM 不足、WorkGroup 不一致、Glue 権限不足 | 使用ロールと `fw-log-analytics-wg` 指定を確認する |
| HIVE_BAD_DATA | traffic 以外混入、想定外書式、gzip 破損 | 問題ファイルを展開し、`type="traffic"` と必要フィールドを確認する |
| パーティションが増えない | `upload-fortigate-logs.sh` の Glue 登録失敗 | syslog サーバ上のスクリプト実行ログと `glue:GetTable` / `BatchCreatePartition` 権限を確認する |

## 11) コスト設計（S3ライフサイクル、Athenaコスト注意）
### S3 ライフサイクル
- `fortigate/`
  - 0-29 日: `STANDARD`
  - 30 日以降: `STANDARD_IA`
  - `fortigate_retention_days` 経過後に削除（既定 365 日）
  - 旧版は `fortigate_noncurrent_retention_days` 経過後に削除（既定 30 日）
- `athena-results/`
  - `athena_results_retention_days` 経過後に削除（既定 30 日）
  - 旧版は `athena_results_noncurrent_retention_days` 経過後に削除（既定 7 日）

### Athena コスト最適化
- 課金はスキャン量依存のため、`year/month/day` 条件を必須化する
- `.log.gz` 圧縮保存を標準とする
- WorkGroup でスキャン上限を設定する
  - 既定: `20GB/クエリ`
- 初回検索は `LIMIT` と狭い期間で対象確認する
- 現行の `text + gzip + RegexSerDe` は低コスト重視であり、低遅延検索を最優先にした構成ではない

**設計意図**
- まずは「不要な全件走査を避ける」運用でコストを抑える
- 性能課題が顕在化した時点で Parquet 化を次段として検討する

## 12) リポジトリ構成案（Terraformファイル構成、将来のmodules化方針）
```text
terraform-fw-log-analytics/
├─ spec.md
├─ README.md
├─ roadmap.md
├─ runbook/
│  ├─ athena-search.md
│  ├─ sql-templates.md
│  ├─ terraform-validation.md
│  ├─ terraform-destroy-policy.md
│  └─ dod-checklist.md
├─ scripts/
│  ├─ 30-fortigate.conf
│  ├─ upload-fortigate-logs.sh
│  └─ upload-fortigate.example
├─ samples/
│  └─ fortigate/year=2026/month=03/day=05/sample.log.gz
├─ images/
│  └─ *.png
└─ terraform/
   ├─ versions.tf
   ├─ providers.tf
   ├─ variables.tf
   ├─ locals.tf
   ├─ s3.tf
   ├─ glue.tf
   ├─ athena.tf
   ├─ iam.tf
   ├─ iam_ingest_user.tf
   ├─ outputs.tf
   ├─ envs/
   │  ├─ dev.tfvars
   │  └─ prod.tfvars
   └─ tests/
      ├─ iam-policy-simulator.ps1
      └─ terraform-validation.ps1
```

**modules 化方針**
- 現在は単一スタックで学習と再現性を優先する
- `stg/prod` 追加や再利用要求が強くなった段階で、`s3/glue/athena/iam` 単位の modules 化を検討する

## 13) 受け入れ条件（Definition of Done）
- Terraform で `init/plan/apply` が成功し、手作業なしで環境作成できる
- `fw-log-analytics-<env>-<random>` バケットに Public Access Block、暗号化、Versioning、Lifecycle が適用される
- Glue DB `fw_log_analytics` とテーブル `fortigate_logs` が作成される
- Athena WorkGroup `fw-log-analytics-wg` が作成され、出力先が強制される
- syslog サーバ側の補助ファイルと cron 設定例が文書化される
- サンプルログ投入後、テンプレート SQL で `srcip/dstip/期間/action` 検索が実行できる
- README と Runbook に標準検索手順、失敗時の切り分け、再現手順が記載される
- `terraform destroy` の実行可否方針（誤削除防止設定を含む）が文書化される

## 14) リスク・制約・未決事項（質問事項もここに列挙）
### リスク・制約
- text + gzip + RegexSerDe のため、ローカル `grep` より常に高速とは限らない
- FortiGate ログの書式揺れにより Regex 抽出率が低下する可能性がある
- event/system ログは現行テーブルの検索対象外である
- syslog サーバ自体の構築・監視・冗長化は Terraform 管理対象外である
- 検索者に原文ログ `GetObject` を許可しているため、利用者拡大時は持ち出し統制の再評価が必要になる

### Issue 01 で確定した決定事項
- 保管期間は既定 1 年、要件に応じて 5 年まで延長可能な設計とする
- パーティション基準日は JST で統一する
- 暗号化は検証で SSE-S3、本番で SSE-KMS を使用する
- 検索者ロール（インフラエンジニア）には原文ログを含む `GetObject` を許可する
- 想定ログ量は 0.5-2GB/日（生ログ）、同時実行は最大 10 件とする

### 未決事項
- `action` 正規化列（`action_norm`）を追加するかは将来課題とする
- ETL / Parquet 化の具体方式は未決とする
