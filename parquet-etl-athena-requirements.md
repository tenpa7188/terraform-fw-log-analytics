# Athena 方式 Parquet 化 要件定義ドラフト

## 1. 文書の目的
- 本文書は、`terraform-fw-log-analytics` に Parquet 化を追加する際の**要件定義ドラフト**である。
- 比較資料 [parquet-etl-options.md](parquet-etl-options.md) を踏まえ、**Athena CTAS / INSERT INTO 方式を採用する前提**で、何を満たすべきかを整理する。
- 本文書は次フェーズの設計・実装・Issue 分解の基準文書として使用する。

## 2. 背景
- 現行は `text + gzip + RegexSerDe` により Athena で検索可能である。
- ただし、大量ログ検索では次の課題が残る。
  - スキャン量が増えやすい
  - 実行時間が安定しない
  - `raw_line` を含む text テーブルは検索性能の観点で改善余地がある
- 一方で、raw ログは調査・監査・フォールバックのため継続保管が必要である。

## 3. 本対応の目的
- **検索速度向上を必須要件として達成する**
- Athena 検索のスキャン量と実行時間を改善する
- raw ログを残したまま、**標準検索向けの Parquet テーブル**を追加する
- 現行の S3 / Glue / Athena 基盤を活かし、構成変更を最小限に抑える
- 学習・PoC として実装しやすく、将来 Glue ETL へ移行可能な構成にする

## 4. 採用方針
- **採用方式**: Athena CTAS / INSERT INTO
- **採用理由**
  - 現行の raw テーブル `fw_log_analytics.fortigate_logs` をそのまま利用できる
  - 新規に追加する AWS コンポーネントが少ない
  - SQL ベースで変換ロジックを定義でき、学習しやすい
  - まず PoC として性能差・コスト差を測りやすい

## 5. スコープ

### 5.1 今回のスコープ
- raw テーブルを入力にした Parquet テーブルを追加する
- Parquet テーブルを Athena の標準検索候補として使える状態にする
- 日次で当日分または前日分を Parquet へ追記できる構成を定義する
- Terraform で必要な Glue / Athena / IAM / S3 設定を追加する
- Runbook / README / SQL テンプレートを Parquet 対応に更新する

### 5.2 今回のスコープ外
- Glue ETL Job への移行
- Lambda 方式への移行
- event / utm / vpn ログまで含めた多系統 ETL
- OpenSearch 連携
- GUI 検索画面

## 6. 前提条件
- raw ログは継続して `fortigate/year=YYYY/month=MM/day=DD/` に保管する
- 現行の syslog サーバからの S3 アップロード方式は維持する
- 変換対象はまず `traffic` ログのみとする
- 変換基準日は JST とする
- raw テーブル `fw_log_analytics.fortigate_logs` は継続利用する
- Parquet 化は raw の置き換えではなく、**別系統の追加**とする

## 7. To-Be アーキテクチャ
```text
[FortiGate]
    |
    v
[syslogサーバ]
  - traffic ログを S3 raw prefix へアップロード
    |
    v
[S3 raw]
  s3://<bucket>/fortigate/year=YYYY/month=MM/day=DD/*.log.gz
    |
    v
[Glue raw table]
  fw_log_analytics.fortigate_logs
    |
    | Athena CTAS / INSERT INTO
    v
[S3 parquet]
  s3://<bucket>/fortigate-parquet/year=YYYY/month=MM/day=DD/
    |
    v
[Glue parquet table]
  fw_log_analytics.fortigate_logs_parquet
    |
    v
[Athena WorkGroup]
  - 標準検索は Parquet テーブルを優先
  - raw テーブルはフォールバック検索用
```

## 8. 機能要件

### 8.1 データ配置
- raw ログは従来どおり保持する
- Parquet 出力先を新設する
  - 確定 prefix: `fortigate-parquet/year=YYYY/month=MM/day=DD/`
- raw と Parquet を同一バケット内で管理できること

### 8.2 入力元
- 変換元は `fw_log_analytics.fortigate_logs` とする
- 入力条件は `year/month/day` を必須にし、日付単位で変換できること

### 8.3 出力先テーブル
- Parquet 用 Glue Table を新規作成する
- 確定テーブル名: `fw_log_analytics.fortigate_logs_parquet`
- パーティションキーは raw と同じ `year`, `month`, `day` とする

### 8.4 出力列
- Parquet テーブルの対象列は次を最小構成とする
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

### 8.5 `raw_line` の扱い
- Parquet テーブルには **`raw_line` を含めない**方針を基本とする
- 理由
  - 標準検索は構造化列中心でよい
  - `raw_line` を持たせると Parquet 化の効果が薄れやすい
- フォールバック検索は raw テーブルで継続する

### 8.6 実行方式
- 初回バックフィル
  - **1 年分を日単位の `INSERT INTO` で実施する**
- 日次増分
  - `year/month/day` 単位で Parquet へ追記できること
- 実行は自動化可能であること
  - 手動実行のみで終わらせない
- 日次実行の契機
  - **AWS 側スケジュール実行**とする
  - syslog サーバは raw を S3 に配置する責務までに留める

### 8.7 冪等性
- 同じ日付を二重投入しないこと
- 再実行時は**対象日を再生成**すること
  - 対象日付の Parquet 出力を削除する
  - raw テーブルから対象日を再変換する
  - 重複データを残さない

## 9. 非機能要件

### 9.1 性能
- **Parquet 化 ETL は検索速度を上げることを必須要件とする**
- 同一条件の検索において、raw テーブルより Parquet テーブルの方が**スキャン量が少ない**こと
- 同一条件の検索において、raw テーブルより Parquet テーブルの方が**実行時間が短い**こと
- 標準検索先の切替条件は次とする
  - raw 比で**スキャン量減少**を確認できること
  - raw 比で**実行時間短縮**を確認できること
- 少なくとも次の観点で改善を確認する
  - `srcip`
  - `dstip`
  - `action`
  - 期間指定

### 9.2 コスト
- 日次変換コストは低く抑える
- 2GB / 回の変換で、Athena 方式の概算コストを把握できること
- 検索時のスキャン量削減により、トータルでコスト最適化が見込めること

### 9.3 セキュリティ
- raw / Parquet の両方で公開禁止、暗号化、TLS 強制を維持する
- 変換実行に必要な IAM 権限は最小限とする
- Parquet 追加により不要な高権限を与えない

### 9.4 運用性
- 失敗時に再実行方法が明確であること
- raw テーブルを残し、Parquet 側失敗時も検索手段を失わないこと
- Runbook から標準検索先とフォールバック検索先が分かること

### 9.5 再現性
- Terraform で必要リソースを再現可能であること
- サンプルデータまたは検証データで PoC を再現できること

## 10. 設計上の前提ルール
- raw は原本、Parquet は検索最適化用の派生データと位置づける
- 標準検索は、性能確認後に Parquet 優先へ切り替える
- 異常時・抽出漏れ確認は raw テーブルを使う
- event ログは今回の Parquet 化対象に含めない
- raw と Parquet は**同一 S3 バケット内**で管理する

## 11. Terraform で必要となる追加対象
- S3
  - Parquet 用 prefix を運用対象として扱う
- Glue
  - Parquet 用テーブル追加
- IAM
  - Athena 変換実行に必要な権限追加
- 必要に応じて Athena 実行用の補助リソース

## 12. ドキュメント更新対象
- [README.md](README.md)
- [spec.md](spec.md)
- [runbook/athena-search.md](runbook/athena-search.md)
- [runbook/sql-templates.md](runbook/sql-templates.md)

## 13. Definition of Done
- raw と Parquet の 2 系統構成が文書化されている
- Parquet 用 Glue Table が作成される
- Parquet 用 S3 prefix が定義される
- Athena 方式で日次変換する方法が定義される
- `srcip/dstip/期間/action` の検索で、Parquet 側のスキャン量が raw より少ないことを確認できる
- raw を使ったフォールバック手順が残っている
- README / Runbook / SQL テンプレートが更新されている

## 14. リスク
- `CTAS` / `INSERT INTO` の SQL が複雑になると保守性が落ちる
- 小さい Parquet ファイルが増えすぎると、逆に性能が不安定になる可能性がある
- 再実行戦略を曖昧にすると、重複データや欠損の原因になる
- `raw_line` を Parquet から外すため、標準検索外の調査は raw テーブル依存になる

## 15. 未決事項
- なし

## 16. 今回確定した要件
- raw と Parquet は**同一 S3 バケット**で管理する
- Parquet 出力 prefix は `fortigate-parquet/` とする
- Parquet テーブル名は `fortigate_logs_parquet` とする
- 日次実行の契機は **AWS 側スケジュール実行**とする
- 初回バックフィルは **1 年分を日単位の `INSERT INTO`** で実施する
- 再実行方針は **対象日を再生成**とする
- 標準検索先は、raw 比で**スキャン量減少**かつ**実行時間短縮**を確認した後に Parquet 優先へ切り替える
