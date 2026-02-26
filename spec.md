# terraform-fw-log-analytics 仕様書（spec.md）

## 1) 目的・背景
本リポジトリ `terraform-fw-log-analytics` の目的は、FortiGate想定のFWログを低コストかつ安全に保管し、AthenaでIP検索を高速・標準化することです。

- 現状課題: 1年分ログのgrep検索に時間がかかる、検索手順が属人化している
- 解決方針: S3 + Glue Data Catalog + Athena + IAM をTerraformで再現可能に構築する
- 目標:
- **検索高速化**（パーティション前提のクエリでスキャン量を削減）
- **検索手順標準化**（SQLテンプレートとRunbookを提供）
- **安全運用**（公開防止、暗号化、誤削除対策、最小権限）

**仮定**

- AWSアカウントは1つ、初期は `dev` 環境で検証し、将来 `stg/prod` に横展開する
- ログは `key=value` の1行1イベント（syslog風テキスト）としてS3に投入される
- ログ投入時点で `.log.gz` 形式に圧縮される
- パーティション日付は原則 `date` フィールド（イベント発生日）を使用する
- Terraform実行者は必要な管理権限を持つ

## 2) 用語定義
| 用語 | 定義 |
|---|---|
| S3 Prefix | バケット内の論理パス。`fortigate/year=YYYY/month=MM/day=DD/` を採用 |
| Partition | Athenaのスキャン対象を絞るための分割キー（`year/month/day`） |
| Glue Data Catalog | Athenaが参照するメタデータ（DB/テーブル定義） |
| WorkGroup | Athenaの実行単位。出力先や上限制御を強制できる |
| 最小権限 | 必要最小限の操作のみ許可するIAM設計方針 |
| 生ログ検索 | 構造化抽出が失敗した場合に `raw_line` 文字列へ正規表現を適用して検索する方法 |

## 3) 全体アーキテクチャ（テキスト図）
```text
[FortiGateログ(テキスト, gzip)]
          |
          | (手動投入 or 将来の収集経路)
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
  - 必要に応じクエリスキャン上限
          |
          v
[利用者(運用者/監査担当)]
  - 標準SQLテンプレートで srcip/dstip/期間/action を検索

(全リソースはTerraformで作成・更新・破棄可能)
```

**設計意図**: AWSマネージドサービス中心で構成し、運用負荷を下げながら再現性を確保する。

## 4) スコープ
- Terraformで以下を作成
 - S3（ログ保管、クエリ結果出力先）
 - Glue Data Catalog（DB/テーブル）
 - Athena WorkGroup（出力先強制）
 - IAM（最小権限）
- 日付パーティション前提のS3パス設計
- AthenaでIP検索できるSQLテンプレートを仕様化
- README/Runbookで検索手順を統一
- FortiGateからAWSへの本番収集経路の完全実装
- Parquet変換やETL最適化
- GUI検索画面の実装

## 5) 機能要件（S3/Glue/Athena/IAM）
| コンポーネント | 要件 | 設計意図 |
|---|---|---|
| S3 | バケット名は `fw-log-analytics-<env>-<random>` | 命名一貫性とグローバル重複回避 |
| S3 | Public Access Blockを全有効化 | 誤公開防止 |
| S3 | バケットデフォルト暗号化を有効化（初期: SSE-S3） | 運用簡素化と暗号化担保 |
| S3 | Versioning有効化 | 誤削除・上書き復旧 |
| S3 | ライフサイクル設定 | 保管コスト最適化 |
| Glue | DB名 `fw_log_analytics` | 固定命名で運用手順を統一 |
| Glue | テーブル名 `fortigate_logs` | 固定命名でクエリ互換性維持 |
| Athena | WorkGroup名 `fw-log-analytics-wg` | チーム標準実行経路の強制 |
| Athena | 出力先を `s3://<bucket>/athena-results/` に固定 | 結果散逸防止・監査容易化 |
| IAM | ログ投入権限、検索権限、Terraform実行権限を分離 | 誤操作影響の局所化 |
| IAM | 検索者は原則Read/Queryのみ | 最小権限徹底 |

## 6) データ設計（S3パス設計、partition設計、命名）
### S3パス設計
- ログ保存先: `s3://fw-log-analytics-<env>-<random>/fortigate/year=YYYY/month=MM/day=DD/xxxxx.log.gz`
- Athena結果: `s3://fw-log-analytics-<env>-<random>/athena-results/`

### パーティション設計
- パーティションキー: `year`, `month`, `day`
- 形式: `year=2026/month=02/day=27`（ゼロ埋め固定）
- 基準: **イベント発生日**（`date` フィールド）を優先
- 検索ルール: クエリ時は必ず `year/month/day` を条件に含める

### ログ行の想定形式
```text
date=2026-02-27 time=12:34:56 srcip=1.2.3.4 dstip=5.6.7.8 action=accept ...
```

### 抽出対象フィールド
- `date`
- `time`
- `srcip`
- `dstip`
- `srcport`
- `dstport`
- `proto`
- `action`
- `policyid`
- `raw_line`（元ログ全文）

**設計意図**: よく使う検索軸（IP、期間、action）を最短で引ける最小構成に絞る。

## 7) Athenaテーブル設計方針（最低1案＋代替案）
### 案A（採用）: 構造化テーブル + `raw_line` 併用
- テーブル: `fw_log_analytics.fortigate_logs`
- 方針: RegexSerDeで主要フィールドを抽出し、同時に `raw_line` を保持
- 利点: SQL可読性が高く、運用者間で検索観点を統一しやすい
- 注意: ログ書式揺れが大きいと抽出率が下がる可能性がある

### 案B（代替）: 生ログ中心テーブル
- テーブル: `fortigate_logs` を `raw_line` 主体で定義
- 方針: `regexp_extract` をクエリ側で適用
- 利点: フォーマット変化に強い
- 欠点: クエリが複雑化し、人的ミスが増えやすい

### 採用判断基準
- 抽出失敗率が低い間は案Aを採用
- 抽出失敗率が高い場合は案Bに切替、将来ETL（Parquet化）を検討

## 8) 検索仕様（IP検索を中心にSQLテンプレを複数）
**共通ルール**

- WorkGroupは `fw-log-analytics-wg` を使用
- 初回は `LIMIT 1000` を付けて確認後、必要に応じて拡張
- **必ずパーティション条件（year/month/day）を指定**

### テンプレート1: srcip検索（期間 + action）
```sql
SELECT log_date, log_time, srcip, dstip, dstport, action, policyid
FROM fw_log_analytics.fortigate_logs
WHERE year = '2026'
  AND month = '02'
  AND day BETWEEN '20' AND '27'
  AND srcip = '1.2.3.4'
  AND action IN ('accept', 'deny')
ORDER BY log_date, log_time
LIMIT 1000;
```

### テンプレート2: dstip検索（期間指定）
```sql
SELECT log_date, log_time, srcip, dstip, srcport, dstport, proto, action
FROM fw_log_analytics.fortigate_logs
WHERE year = '2026'
  AND month = '02'
  AND day BETWEEN '01' AND '27'
  AND dstip = '5.6.7.8'
ORDER BY log_date, log_time
LIMIT 1000;
```

### テンプレート3: IP双方向検索（src/dstどちらでも一致）
```sql
SELECT log_date, log_time, srcip, dstip, action, policyid
FROM fw_log_analytics.fortigate_logs
WHERE year = '2026'
  AND month = '02'
  AND day BETWEEN '01' AND '27'
  AND ('1.2.3.4' IN (srcip, dstip))
ORDER BY log_date, log_time
LIMIT 1000;
```

### テンプレート4: 生ログフォールバック検索（抽出失敗時）
```sql
SELECT "$path", raw_line
FROM fw_log_analytics.fortigate_logs
WHERE year = '2026'
  AND month = '02'
  AND day = '27'
  AND regexp_like(raw_line, '(^| )srcip=1\\.2\\.3\\.4( |$)|(^| )dstip=1\\.2\\.3\\.4( |$)')
LIMIT 1000;
```

## 9) セキュリティ設計（最小権限の考え方、公開禁止、暗号化）
- S3 Public Access Blockを全有効化し、ACL/Policyの誤設定公開を防止
- バケットデフォルト暗号化を有効化（初期: SSE-S3、将来: SSE-KMS）
- バケットポリシーで `aws:SecureTransport = false` を拒否（TLS強制）
- IAMロールを責務分離
- `ingest` ロール: `fortigate/` への `PutObject` 中心
- `analyst` ロール: Athena実行、Glue参照、S3ログ読み取り、結果書き込み
- `terraform` 実行主体: インフラ管理操作のみ
- `DeleteObject` や `PutBucketPolicy` など高権限操作を検索者ロールから除外
- Versioning有効化で誤削除復旧可能にする

**設計意図**: 「見える人」と「壊せる人」を分け、事故時の被害を最小化する。

## 10) 運用設計（ログ投入、検索の標準手順、トラブル時の切り分け）
### 標準手順（構築）
```bash
cd terraform
terraform init
terraform validate
terraform plan -var-file=envs/dev.tfvars
terraform apply -var-file=envs/dev.tfvars
```

### 標準手順（ログ投入）
- 対象日付のプレフィックスへ `.log.gz` を配置
- 例: `fortigate/year=2026/month=02/day=27/`
- 失敗時はIAM権限とパス形式を先に確認

### 標準手順（検索）
- Runbook記載のテンプレートSQLを利用
- 必須入力は `IP`, `期間`, `action条件`
- 実行履歴にチケット番号を残す（監査性確保）

### トラブル切り分け
| 症状 | 主な原因 | 一次対応 |
|---|---|---|
| Athena結果が0件 | パーティション日付不一致、IP入力ミス | S3実ファイル配置と `year/month/day` 条件を再確認 |
| HIVE_BAD_DATA系エラー | Regex抽出不一致、想定外書式 | テンプレート4の生ログ検索で存在確認 |
| AccessDenied | IAM不足、WorkGroup不一致 | 利用ロールと `fw-log-analytics-wg` 指定を確認 |
| コスト急増 | パーティション条件不足 | 必須条件ルールをRunbookで再徹底 |

## 11) コスト設計（S3ライフサイクル、Athenaコスト注意）
### S3ライフサイクル（例）
- 0-30日: S3 Standard
- 31-180日: Standard-IA
- 181-365日: Glacier Instant Retrieval
- 366日以降: Deep Archive または削除（保管要件に従う）

### Athenaコスト最適化
- 課金はスキャンデータ量依存のため、パーティション条件を必須化
- `.log.gz` 圧縮保存を標準とする
- WorkGroupでスキャン上限案を設定（例: 10GB/クエリ）
- 初回は `LIMIT` と狭い期間で探索し、段階的に範囲拡大

**設計意図**: まず「無駄に読まない」運用ルールでコストを抑制する。

## 12) リポジトリ構成案（Terraformファイル構成、将来のmodules化方針）
```text
terraform-fw-log-analytics/
├─ spec.md
├─ README.md
├─ runbook/
│  └─ athena-search.md
├─ samples/
│  └─ fortigate/year=2026/month=02/day=27/sample.log.gz
└─ terraform/
   ├─ versions.tf
   ├─ providers.tf
   ├─ variables.tf
   ├─ locals.tf
   ├─ main.tf
   ├─ s3.tf
   ├─ glue.tf
   ├─ athena.tf
   ├─ iam.tf
   ├─ outputs.tf
   ├─ envs/
   │  ├─ dev.tfvars
   │  └─ prod.tfvars
   └─ modules/        # 将来フェーズで分割
      ├─ s3-log-bucket/
      ├─ glue-catalog/
      ├─ athena-workgroup/
      └─ iam-access/
```

**modules化方針**: 初期は単一スタックで迅速実装し、環境追加や再利用要求が出た段階で分割する。

## 13) 受け入れ条件（Definition of Done）
- Terraformで `init/plan/apply` が成功し、手作業なしで環境作成できる
- `fw-log-analytics-<env>-<random>` バケットにPublic Access Block、暗号化、Versioning、Lifecycleが適用される
- Glue DB `fw_log_analytics` とテーブル `fortigate_logs` が作成される
- Athena WorkGroup `fw-log-analytics-wg` が作成され、出力先が強制される
- サンプルログ投入後、テンプレートSQLで `srcip/dstip/期間/action` 検索が実行できる
- README と Runbook に標準検索手順、失敗時の切り分け、再現手順が記載される
- `terraform destroy` の実行可否方針（誤削除防止設定を含む）が文書化される

## 14) リスク・制約・未決事項（質問事項もここに列挙）
### リスク・制約
- FortiGateログの書式揺れによりRegex抽出率が低下する可能性
- テキスト検索中心のため、データ量増加時にAthenaコストが上がりやすい
- 収集経路（FortiGate→AWS）未実装のため、本番運用の完全自動化は未達
- 誤った日付パーティション投入で検索漏れが発生しうる

### 未決事項（質問）
- 保管期間は厳密に1年か、監査要件で延長が必要か
- パーティション基準日は `JST` と `UTC` のどちらで統一するか
- 暗号化はSSE-S3で十分か、初期からSSE-KMS必須か
- 検索者ロールに `GetObject` のみ付与するか、限定的なダウンロード権限を認めるか
- 想定ログ量（GB/日）と同時実行数はいくつか（WorkGroup上限設定の前提）
- `action` の値表記（`accept/deny` など）を正規化するか、そのまま保持するか
