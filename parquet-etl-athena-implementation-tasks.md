# Athena 方式 Parquet 化 実装タスク分解

## 1. 文書の目的
- 本文書は、[parquet-etl-athena-design.md](parquet-etl-athena-design.md) を実装へ落とし込むためのタスク分解である。
- Terraform、Lambda、SQL、Runbook、検証をどの順で作るかを明確にし、手戻りを減らすことを目的とする。

## 2. タスク分解の方針
- 先に **AWS リソースの土台** を Terraform で追加する
- 次に **Lambda と SQL** を実装する
- その後に **バックフィル補助スクリプト** と **ドキュメント** を整備する
- 最後に **性能比較と標準検索先切替判断** を行う

## 3. フェーズ一覧

| フェーズ | 目的 | 主な成果物 |
| --- | --- | --- |
| Phase 1 | Terraform 土台追加 | Glue テーブル、Athena WorkGroup、IAM、Lambda / Scheduler 定義 |
| Phase 2 | Lambda / SQL 実装 | ETL 実行 Lambda、SQL テンプレート |
| Phase 3 | 補助スクリプト整備 | PowerShell バックフィル実行スクリプト |
| Phase 4 | ドキュメント更新 | README、Runbook、SQL テンプレート説明 |
| Phase 5 | 検証と切替判断 | E2E、性能比較、標準検索先切替判断 |

## 4. Phase 1: Terraform 土台追加

### Task 1-1: Parquet 用 Glue テーブル追加
- 目的:
  - `fw_log_analytics.fortigate_logs_parquet` を Terraform で作成できるようにする
- 対象:
  - `terraform/glue.tf`
- 実装内容:
  - Parquet テーブル定義追加
  - ルート location を `fortigate-parquet/` に設定
  - 列型を詳細設計どおり反映
  - パーティション列 `year/month/day` を追加
- 確認方法:
  - `terraform validate`
  - `terraform plan -var-file="envs/dev.tfvars"` で Glue Table 追加差分を確認

### Task 1-2: ETL 用 Athena WorkGroup 追加
- 目的:
  - 検索用 WorkGroup と ETL 用 WorkGroup を分離する
- 対象:
  - `terraform/athena.tf`
- 実装内容:
  - `fw-log-analytics-etl-wg` を追加
  - 結果出力先を `athena-results/etl/` に設定
  - 設定強制を有効化
- 確認方法:
  - `terraform plan` で WorkGroup 追加差分を確認

### Task 1-3: Lambda 実行ロール追加
- 目的:
  - ETL 実行用の最小権限ロールを用意する
- 対象:
  - `terraform/iam.tf`
- 実装内容:
  - Athena ETL 用ロール作成
  - Athena / Glue / S3 / CloudWatch Logs 権限付与
  - 検索者ロール、ingest ロールと分離
- 確認方法:
  - `terraform plan` で IAM 追加差分を確認

### Task 1-4: Lambda / Scheduler リソース追加
- 目的:
  - ETL 実行基盤を Terraform 管理にする
- 対象:
  - 新規作成候補:
    - `terraform/lambda.tf`
    - `terraform/scheduler.tf`
- 実装内容:
  - Lambda 関数定義
  - EventBridge Scheduler 定義
  - 環境変数、ZIP 参照、ロール紐付け
- 確認方法:
  - `terraform plan` で Lambda / Scheduler 差分を確認

## 5. Phase 2: Lambda / SQL 実装

### Task 2-1: 日次 ETL SQL ファイル作成
- 目的:
  - Athena `INSERT INTO` を別ファイルで管理する
- 対象:
  - 新規作成候補:
    - `sql/parquet/insert_daily.sql`
- 実装内容:
  - raw から Parquet への日次変換 SQL
  - パラメータ埋め込み前提のテンプレート化
- 確認方法:
  - Athena クエリ文字列として不整合がないことを確認

### Task 2-2: Lambda ハンドラー実装
- 目的:
  - 日次 / backfill / rebuild を 1 本の Lambda で扱えるようにする
- 対象:
  - 新規作成候補:
    - `lambda/parquet_etl_runner/app.py`
- 実装内容:
  - mode 判定
  - 対象日計算
  - 直近 7 日 catch-up 判定
  - raw / parquet prefix 存在確認
  - dry-run 相当ログ出力
  - Athena 実行と完了待ち
- 確認方法:
  - Python 構文チェック
  - イベントサンプルでのロジック確認

### Task 2-3: Lambda パッケージ化手順整備
- 目的:
  - Lambda 配布方法を固定する
- 対象:
  - 新規作成候補:
    - `scripts/build-parquet-lambda.ps1`
- 実装内容:
  - ZIP 化手順
  - Terraform 参照先と整合する配置
- 確認方法:
  - ZIP が生成されること
  - Terraform 参照パスと一致すること

## 6. Phase 3: 補助スクリプト整備

### Task 3-1: 初回バックフィル用 PowerShell スクリプト作成
- 目的:
  - 1 年分を日単位で Lambda 呼び出しできるようにする
- 対象:
  - 新規作成候補:
    - `scripts/invoke-parquet-backfill.ps1`
- 実装内容:
  - 開始日 / 終了日を受け取り
  - 1 日ずつ Lambda を呼ぶ
  - 失敗日の停止 / 再開しやすいログ出力
- 確認方法:
  - dry-run オプションがあること
  - 日付ループが正しいこと

### Task 3-2: 再生成実行用 PowerShell スクリプト作成
- 目的:
  - rebuild を安全に手動起動できるようにする
- 対象:
  - 新規作成候補:
    - `scripts/invoke-parquet-rebuild.ps1`
- 実装内容:
  - 対象日指定
  - Lambda を `mode=rebuild` で呼び出す
  - dry-run 相当ログ確認
- 確認方法:
  - 対象日が正しくイベントに入ること

## 7. Phase 4: ドキュメント更新

### Task 4-1: README 更新
- 目的:
  - Parquet 化の位置づけと実行基盤を README に反映する
- 対象:
  - `README.md`
- 実装内容:
  - raw / parquet の役割分担
  - ETL 用 WorkGroup
  - Lambda / Scheduler の概要
- 確認方法:
  - README だけで構成意図が追えること

### Task 4-2: Runbook 更新
- 目的:
  - 運用手順を raw / parquet 両対応にする
- 対象:
  - `runbook/athena-search.md`
  - `runbook/sql-templates.md`
- 実装内容:
  - 標準検索は Parquet 優先
  - raw はフォールバック
  - ETL 失敗時の切り分け
- 確認方法:
  - 手順が利用者目線で追えること

## 8. Phase 5: 検証と切替判断

### Task 5-1: E2E 動作確認
- 目的:
  - raw -> Athena ETL -> Parquet 検索までの一連を確認する
- 対象:
  - AWS 環境
- 実装内容:
  - Lambda 手動起動
  - Parquet prefix 作成確認
  - Glue / Athena 確認
- 確認方法:
  - 1 日分で Parquet 検索が通ること

### Task 5-2: 性能比較
- 目的:
  - raw / Parquet の性能差を判断する
- 対象:
  - 1日 / 30日 / 365日
- 実装内容:
  - 4 本の比較 SQL を 3 回ずつ実行
  - 実行時間・スキャン量を記録
- 確認方法:
  - 中央値で raw 比改善を確認する

### Task 5-3: 標準検索先切替判断
- 目的:
  - Parquet を標準検索先に切り替えるかを判断する
- 対象:
  - README / Runbook / SQL テンプレート
- 実装内容:
  - 切替条件判定
  - 文書更新
- 確認方法:
  - 利用者が Parquet 優先で迷わず検索できること

## 9. 実装順序の推奨
1. Phase 1-1 〜 1-4
2. Phase 2-1 〜 2-3
3. Phase 3-1 〜 3-2
4. Phase 4-1 〜 4-2
5. Phase 5-1 〜 5-3

## 10. 補足
- No.4 と No.6 は仮設定のため、実装後に実測結果で見直す前提とする。
- 実装時は、[parquet-etl-athena-design-checksheet.md](parquet-etl-athena-design-checksheet.md) の決定内容を逸脱しないことを確認する。
