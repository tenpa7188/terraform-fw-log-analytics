# terraform-fw-log-analytics 実装タスク（1タスク=1チケット）

## Issue 01: 未決事項を確定して設計前提をロックする
- 背景: 仕様書の未決事項が残るとTerraform実装時に手戻りが出る。
- 目的: 命名、保持期間、タイムゾーン、暗号化方針を確定する。
- 作業内容: 未決事項を一覧化し、採用方針を `spec.md` に追記する。
- 受け入れ条件: 未決事項が「決定済み」または「次フェーズへ明示」で整理されている。
- 依存関係: なし

## Issue 02: リポジトリ骨格を作成する
- 背景: 実装ファイルの配置が未整備だと運用・拡張しにくい。
- 目的: Terraform実装と運用ドキュメントの配置を標準化する。
- 作業内容: `terraform/`, `runbook/`, `samples/` を作成する。
- 受け入れ条件: ディレクトリ構成が仕様書12章と整合する。
- 依存関係: Issue 01

## Issue 03: Terraform基本ファイルを作成する
- 背景: Provider/Version/Variable定義の基盤が必要。
- 目的: 実装開始可能なTerraformの最小構成を作る。
- 作業内容: `versions.tf`, `providers.tf`, `variables.tf`, `locals.tf`, `outputs.tf`, `main.tf` を作成する。
- 受け入れ条件: `terraform init` と `terraform validate` が通る。
- 依存関係: Issue 02

## Issue 04: 環境別tfvarsを作成する
- 背景: dev/prod差分をコードで分離する必要がある。
- 目的: 環境ごとの設定切替を再現可能にする。
- 作業内容: `envs/dev.tfvars` と `envs/prod.tfvars` を作成し、必須変数を定義する。
- 受け入れ条件: `terraform plan -var-file="envs/dev.tfvars"` が実行できる。
- 依存関係: Issue 03

## Issue 05: バケット命名ロジックを実装する
- 背景: S3バケット名はグローバル一意が必要。
- 目的: `fw-log-analytics-<env>-<random>` を自動生成する。
- 作業内容: `random_id` などでsuffixを生成し、localsでバケット名を組み立てる。
- 受け入れ条件: plan上で命名規約に一致したバケット名が出力される。
- 依存関係: Issue 03, Issue 04

## Issue 06: S3ログバケット本体を実装する
- 背景: ログ保管の中核リソースが必要。
- 目的: FortiGateログ保存用S3バケットを作成する。
- 作業内容: `s3.tf` にバケットリソースとタグを定義する。
- 受け入れ条件: `terraform apply` 後にバケットが作成される。
- 依存関係: Issue 05

## Issue 07: S3セキュリティ設定を実装する
- 背景: 誤公開と平文転送を防ぐ必要がある。
- 目的: 公開禁止・暗号化・TLS強制を担保する。
- 作業内容: Public Access Block、デフォルト暗号化、`aws:SecureTransport` 拒否ポリシーを設定する。
- 受け入れ条件: すべての設定が有効で、公開アクセス不可になっている。
- 依存関係: Issue 06

## Issue 08: S3 Versioningと誤削除対策を実装する
- 背景: ログ保全と復旧性が必要。
- 目的: 誤削除・上書きへの耐性を持たせる。
- 作業内容: Versioning有効化、必要に応じて削除保護方針をドキュメント化する。
- 受け入れ条件: バケットVersioningが有効である。
- 依存関係: Issue 06

## Issue 09: S3ライフサイクルルールを実装する
- 背景: 長期保管コストを抑制する必要がある。
- 目的: 保存期間に応じてストレージクラスを自動遷移させる。
- 作業内容: Standard→IA→Glacier系への移行ルールを設定する。
- 受け入れ条件: ライフサイクルルールがplan/applyで反映される。
- 依存関係: Issue 06

## Issue 10: Athena結果出力先を設計・実装する
- 背景: クエリ結果の散逸を防ぐ必要がある。
- 目的: `athena-results/` への出力を統一する。
- 作業内容: 出力先prefixを定義し、WorkGroupで強制する前提を整える。
- 受け入れ条件: 出力先が仕様のprefixに固定可能な状態になる。
- 依存関係: Issue 06

## Issue 11: Glue Databaseを実装する
- 背景: Athenaが参照するメタデータDBが必要。
- 目的: `fw_log_analytics` を作成する。
- 作業内容: `glue.tf` に `aws_glue_catalog_database` を定義する。
- 受け入れ条件: DB名が固定命名で作成される。
- 依存関係: Issue 03

## Issue 12: Glue Table `fortigate_logs` を実装する
- 背景: IP検索に必要なスキーマ定義が必要。
- 目的: 抽出対象フィールドと `raw_line` を持つテーブルを作成する。
- 作業内容: RegexSerDe前提でカラム・partitionキー・locationを定義する。
- 受け入れ条件: Athenaでテーブル参照ができる。
- 依存関係: Issue 11, Issue 06

## Issue 13: パーティション運用手順を実装する
- 背景: `year/month/day` 管理が検索性能の前提。
- 目的: パーティション追加漏れを防ぐ。
- 作業内容: `MSCK REPAIR TABLE` または `ALTER TABLE ADD PARTITION` の標準手順をRunbook化する。
- 受け入れ条件: 日次ログ投入後にクエリ対象へ反映できる。
- 依存関係: Issue 12

## Issue 14: Athena WorkGroupを実装する
- 背景: クエリ運用を標準化しコスト制御したい。
- 目的: `fw-log-analytics-wg` を作成し設定を強制する。
- 作業内容: WorkGroup名、結果出力先、必要ならスキャン上限を定義する。
- 受け入れ条件: 指定WorkGroupでのみ標準設定で実行される。
- 依存関係: Issue 10, Issue 03

## Issue 15: IAM最小権限を実装する
- 背景: 権限過多は事故リスクが高い。
- 目的: `ingest` / `analyst` / `terraform` の責務分離を実現する。
- 作業内容: 各ロールとポリシーを作成し、S3/Glue/Athena権限を必要最小化する。
- 受け入れ条件: 想定操作は可能で、不要操作は拒否される。
- 依存関係: Issue 06, Issue 11, Issue 14

## Issue 16: サンプルログ（匿名化/ダミー）を用意する
- 背景: 再現可能な動作確認データが必要。
- 目的: ローカル検証時に同じデータで試験できる状態にする。
- 作業内容: `samples/fortigate/year=YYYY/month=MM/day=DD/sample.log.gz` を作成する。
- 受け入れ条件: サンプル投入後、Athena検索で結果が返る。
- 依存関係: Issue 02

## Issue 17: SQLテンプレートを整備する
- 背景: 検索手順の属人化を排除したい。
- 目的: srcip/dstip/期間/action/フォールバックの標準SQLを提供する。
- 作業内容: 複数テンプレートをRunbookまたはSQLファイルとして記載する。
- 受け入れ条件: 運用者がテンプレートをコピペして検索できる。
- 依存関係: Issue 12, Issue 14

## Issue 18: READMEに構築手順を記載する
- 背景: 初回構築の再現性を担保する必要がある。
- 目的: `terraform apply` までの導線を明確化する。
- 作業内容: 前提条件、コマンド、変数設定例、破棄手順を記載する。
- 受け入れ条件: READMEのみで初期構築が実施できる。
- 依存関係: Issue 03, Issue 04

## Issue 19: Runbookに運用手順を記載する
- 背景: 実運用時の検索・障害対応を統一する必要がある。
- 目的: ログ投入、検索、切り分け手順を標準化する。
- 作業内容: 正常系手順とトラブル時手順を `runbook/athena-search.md` に記載する。
- 受け入れ条件: 0件/AccessDenied/HIVE_BAD_DATAの一次対応が記載されている。
- 依存関係: Issue 13, Issue 17

## Issue 20: Terraform静的検証タスクを整備する
- 背景: 品質担保の自動化が必要。
- 目的: 変更ごとに基本的な構文・整形エラーを防ぐ。
- 作業内容: `terraform fmt`, `terraform validate`, `terraform plan` の実行手順を統一する。
- 受け入れ条件: 検証コマンドを誰でも同じ手順で実行できる。
- 依存関係: Issue 03以降の実装全般

## Issue 21: E2E動作確認を実施する
- 背景: 実際に検索できることを確認しないと価値が出ない。
- 目的: 構築から検索まで一連の成功を証明する。
- 作業内容: apply、サンプル投入、パーティション反映、SQL実行、結果確認を行う。
- 受け入れ条件: srcip/dstip/期間/action検索が仕様どおり成功する。
- 依存関係: Issue 06〜Issue 19

## Issue 22: DoDチェックリストを作成・完了確認する
- 背景: 完了判定を曖昧にしないため。
- 目的: 仕様書13章の受け入れ条件を全て満たしたことを明示する。
- 作業内容: チェックリストを作成し、検証証跡を添えて完了判定する。
- 受け入れ条件: 全項目が確認済みで、未達があれば明示されている。
- 依存関係: Issue 21

## Issue 23: 将来拡張ロードマップを整理する
- 背景: MVP後の拡張方針を先に定義しておくと投資判断しやすい。
- 目的: modules化、ETL/Parquet化、本番収集経路の次アクションを明確化する。
- 作業内容: 優先順位、着手条件、期待効果、リスクを文書化する。
- 受け入れ条件: 次フェーズの計画が1ページで説明できる。
- 依存関係: Issue 22
