# terraform-fw-log-analytics

FortiGate を想定した FW ログを S3 に保管し、Glue Data Catalog と Athena で検索できるようにする Terraform プロジェクトです。

## 背景と課題

- syslog サーバで FW ログ検索をしており、検索対象のログが多いと検索完了まで時間がかかる
- 現場では `grep` や一部ログ抽出を組み合わせて調査しており、担当者ごとに検索手順や観点が異なる
- その結果、検索速度、再現性、引き継ぎやすさに課題がある
- 現行の MVP は検索手順の標準化と再現性確保を優先しており、**大量ログ検索の速度課題そのものはまだ完全には解決していない**

## このプロジェクトで解決したいこと

- 検索を高速化する
  - S3 に保管したログを Athena で検索し、`grep` ベースの属人的な調査より再現しやすい状態にする
  - ただし、現行の `text + gzip + RegexSerDe` 構成では、検索速度は未改善、抜本改善は将来の Parquet 化などで継続対応する
- 検索手順を標準化する
  - SQL テンプレートと Runbook を用意し、担当者ごとのやり方の差を減らす
- ログを安全かつ低コストで保管する
  - S3 の公開禁止、暗号化、バージョニング、ライフサイクル管理を Terraform で再現可能にする

## 作成する AWS リソース

- S3 バケット
  - FortiGate ログ保管用
  - Athena クエリ結果保管用プレフィックスを同一バケット内に作成
- Glue Data Catalog
  - Database: `fw_log_analytics`
  - Table: `fortigate_logs`
- Athena
  - WorkGroup: `fw-log-analytics-wg`
- IAM
  - `ingest` ロール
  - `analyst` ロール
  - `terraform` ロール
  - 必要に応じて `ingest` 専用 IAM ユーザー

## アーキテクチャ概要

```text
FortiGate / syslogサーバ
  -> S3 (fortigate/year=YYYY/month=MM/day=DD/)
  -> Glue Data Catalog
  -> Athena WorkGroup
  -> SQL templates / Runbook
```

## ディレクトリ構成

- [terraform](terraform)
  - Terraform 本体
- [terraform/envs](terraform/envs)
  - 環境別 tfvars
- [runbook](runbook)
  - 検索手順と SQL テンプレート
- [samples](samples)
  - ダミー FortiGate ログ
- [scripts](scripts)
  - syslogサーバ側の補助スクリプトや rsyslog 設定

## 前提条件

- Terraform `>= 1.6.0`
- AWS CLI が利用可能であること
- AWS の認証が通っていること
- 実行リージョンは `ap-northeast-1` を推奨
- Terraform コマンドは `terraform/` ディレクトリで実行する

## 初回構築手順

### 1. リポジトリを確認する

- まず `terraform/` 配下に Terraform ファイルがあることを確認する
- 環境変数は [dev.tfvars](terraform/envs/dev.tfvars) を基準に設定する

### 2. `dev.tfvars` を確認する

対象ファイル:
- [dev.tfvars](terraform/envs/dev.tfvars)

主な設定値:

```hcl
environment = "dev"
aws_region  = "ap-northeast-1"
owner       = "infra"

additional_tags = {
  service             = "fw-log-analytics"
  data_classification = "internal"
}

fortigate_retention_days                 = 365
fortigate_noncurrent_retention_days      = 30
athena_results_retention_days            = 30
athena_results_noncurrent_retention_days = 7
athena_bytes_scanned_cutoff_per_query    = 10737418240
create_ingest_iam_user                   = true
create_ingest_iam_access_key             = false
```

注意:
- `create_ingest_iam_user = true`
  - `ingest` ロールを引き受ける専用 IAM ユーザーを作成する
- `create_ingest_iam_access_key`
  - syslogサーバ などの AWS 外ホストで AWS CLI を使う場合だけ有効化する
  - 公開リポジトリの既定値は `false` とし、不要な長期アクセスキーを作らない
  - アクセスキーのシークレットは Terraform state に保存されるため、本番では扱いに注意する

### 3. `terraform init`

```powershell
terraform init
```

何のために実行するか:
- Terraform Provider を取得し、作業ディレクトリを初期化するためです

どこで実行するか:
- `terraform/`

成功条件:
- `Terraform has been successfully initialized!` が表示されること

### 4. `terraform validate`

```powershell
terraform validate
```

何のために実行するか:
- Terraform 構文とリソース参照関係を確認するためです

どこで実行するか:
- `terraform/`

成功条件:
- `Success! The configuration is valid.` が表示されること

### 5. `terraform plan`

```powershell
terraform plan -var-file="envs/dev.tfvars"
```

何のために実行するか:
- 作成・更新・削除される AWS リソース差分を事前に確認するためです

どこで実行するか:
- `terraform/`

確認すべき点:
- S3 バケット
- Glue Database / Table
- Athena WorkGroup
- IAM ロール
- `create_ingest_iam_user = true` の場合は IAM ユーザーとアクセスキー

### 6. `terraform apply`

```powershell
terraform apply -var-file="envs/dev.tfvars"
```

何のために実行するか:
- AWS 上に実際のリソースを作成するためです

どこで実行するか:
- `terraform/`

成功条件:
- Apply 完了後に outputs が表示されること

## 構築後の確認

### 1. `terraform output`

```powershell
terraform output
```

何のために実行するか:
- 作成された AWS リソース名や ARN を確認するためです

確認対象:
- `log_bucket_name`
- `athena_workgroup_name`
- `glue_database_name`
- `glue_table_name`
- `iam_ingest_role_arn`
- `iam_ingest_user_name`
- `iam_ingest_user_access_key_id`

アクセスキー作成を有効化した場合のみ、シークレット確認が必要になる:

```powershell
terraform output -raw iam_ingest_user_secret_access_key
```

注意:
- シークレットは機微情報として扱う

### 2. AWS コンソール確認

- S3
  - `fw-log-analytics-<env>-<random>` 形式のバケットが作成されていること
- Glue
  - Database `fw_log_analytics`
  - Table `fortigate_logs`
- Athena
  - WorkGroup `fw-log-analytics-wg`

## サンプルログでの確認

サンプルログ:
- [sample.log](samples/fortigate/year=2026/month=03/day=05/sample.log)
- [sample.log.gz](samples/fortigate/year=2026/month=03/day=05/sample.log.gz)

確認の流れ:
1. `sample.log.gz` を S3 の `fortigate/year=2026/month=03/day=05/` 配下へアップロード
2. Athena でパーティションを追加
3. SQL テンプレートで検索確認

関連ドキュメント:
- [sql-templates.md](runbook/sql-templates.md)
- [athena-search.md](runbook/athena-search.md)

## syslogサーバ側の補助ファイル

- [30-fortigate.conf](scripts/30-fortigate.conf)
  - rsyslog で FortiGate の syslog を受ける設定
  - `incoming.log` は traffic 専用
  - `event.log` は event 専用
  - `other.log` は traffic、event以外のログ
- [logrotate-fortigate.conf](scripts/logrotate-fortigate.conf)
  - syslogサーバ上の `incoming.log` / `event.log` / `other.log` を日次でローテートする設定
  - `incoming.log-YYYYMMDD.gz` のようなローテート済み gzip を作成する
- [upload-fortigate-logs.sh](scripts/upload-fortigate-logs.sh)
  - AssumeRole を使って S3 にアップロードするスクリプト
- [upload-fortigate.example](scripts/upload-fortigate.example)
  - スクリプト用設定ファイルのサンプル

実際の配置先の例:

```bash
/etc/rsyslog.d/30-fortigate.conf
/etc/logrotate.d/fortigate
/etc/default/fortigate-uploader
/usr/local/bin/upload-fortigate-logs.sh
/var/log/fortigate/incoming.log
/var/log/fortigate/event.log
/var/log/fortigate/other.log
/var/log/fortigate/uploaded/
```

配置例:

```bash
sudo cp scripts/30-fortigate.conf /etc/rsyslog.d/30-fortigate.conf
sudo cp scripts/logrotate-fortigate.conf /etc/logrotate.d/fortigate
sudo cp scripts/upload-fortigate.example /etc/default/fortigate-uploader
sudo cp scripts/upload-fortigate-logs.sh /usr/local/bin/upload-fortigate-logs.sh
sudo chmod 600 /etc/default/fortigate-uploader
sudo chmod 755 /usr/local/bin/upload-fortigate-logs.sh
sudo mkdir -p /var/log/fortigate/uploaded
```

cron 設定例:

```bash
sudo crontab -e
```

日次実行の例:

```cron
10 1 * * * /usr/local/bin/upload-fortigate-logs.sh >> /var/log/fortigate/upload.log 2>&1
```

補足:
- 例では毎日 `01:10` に前日分のローテート済み gzip ログをアップロードする
- logrotate は OS 標準の日次実行に任せ、`incoming.log-YYYYMMDD.gz` を生成する前提とする
- `/etc/default/fortigate-uploader` に `BUCKET_NAME` と `ROLE_ARN` を設定してから実行する
- `ENABLE_GLUE_PARTITION_ADD="true"` を設定した場合は、アップロード後に Glue へパーティション登録も行う

## 破棄手順

```powershell
terraform destroy -var-file="envs/dev.tfvars"
```

何のために実行するか:
- 検証環境を AWS から削除するためです

どこで実行するか:
- `terraform/`

注意:
- S3 バケットは `force_destroy = false` 前提のため、オブジェクトが残っていると destroy に失敗する
- 失敗時は S3 内のオブジェクトを確認してから再実行する

## Git 管理上の注意

- 次のファイルは GitHub に push しない
  - `terraform/*.tfstate`
  - `terraform/*.tfstate.*`
  - `.terraform/`
- `.terraform.lock.hcl` は Provider バージョン固定のため管理対象

## 今後の拡張候補

- Parquet 変換による Athena コスト最適化
- event ログ用の別テーブル追加
- Terraform modules 化

