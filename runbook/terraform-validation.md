# Terraform Validation Runbook

## 1. 目的
- Terraform の変更ごとに、整形・構文・参照ミスを同じ手順で確認する。
- **`terraform plan` と `terraform apply` はユーザーが実行する**前提で、検証手順だけを標準化する。

## 2. 対象
- 実行ディレクトリ: `terraform/`
- 主な対象ファイル:
  - `*.tf`
  - `envs/*.tfvars`

## 3. 標準手順

### 3.1 `terraform init -backend=false`
```powershell
terraform init -backend=false
```

- 何のために実行するか:
  - Provider を取得し、`validate` や `fmt -check` を実行できる状態にするため
- 何が起こるか:
  - backend 初期化を行わずに Terraform の作業ディレクトリを初期化する
- 成功条件:
  - `Terraform has been successfully initialized!` が表示される

### 3.2 `terraform fmt -check -recursive`
```powershell
terraform fmt -check -recursive
```

- 何のために実行するか:
  - Terraform ファイルの整形崩れを検出するため
- 何が起こるか:
  - 整形が必要なファイルがある場合、そのファイル名が表示されて終了コードが失敗になる
- 成功条件:
  - 何も出力されず正常終了する
- 不一致時の対応:
```powershell
terraform fmt -recursive
```

### 3.3 `terraform validate`
```powershell
terraform validate
```

- 何のために実行するか:
  - 構文、変数参照、リソース参照の整合性を確認するため
- 何が起こるか:
  - Terraform 構成を静的に検証する
- 成功条件:
  - `Success! The configuration is valid.` が表示される

### 3.4 `terraform plan -var-file="envs/dev.tfvars"`
```powershell
terraform plan -var-file="envs/dev.tfvars"
```

- 何のために実行するか:
  - AWS 上でどの差分が発生するかを確認するため
- 何が起こるか:
  - 追加・変更・削除予定のリソース差分が表示される
- 成功条件:
  - 差分、または `No changes.` が表示される
- 注意:
  - `plan` は静的検証ではなく、AWS 認証や現在 state に依存する
  - 実行はユーザーが行う

## 4. 推奨実行順
1. `terraform init -backend=false`
2. `terraform fmt -check -recursive`
3. `terraform validate`
4. 必要時のみ `terraform plan -var-file="envs/dev.tfvars"`

## 5. 補助スクリプト
- `terraform/tests/terraform-validation.ps1` を使うと、上記 1〜3 を同じ順で実行できる
- `-RunPlan` を付けた場合のみ、4 も実行する

実行例:
```powershell
powershell -ExecutionPolicy Bypass -File .\tests\terraform-validation.ps1
```

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\terraform-validation.ps1 -RunPlan
```

## 6. トラブル時の一次対応

### 6.1 `terraform init -backend=false` が失敗する
- 主な原因:
  - Provider ダウンロード失敗
  - ネットワーク疎通不足
  - `terraform/` 以外で実行している
- 対応:
  - 実行ディレクトリを確認する
  - ネットワーク疎通を確認する
  - `.terraform/` を Git 管理していないことを確認する

### 6.2 `terraform fmt -check -recursive` が失敗する
- 主な原因:
  - 整形されていない `.tf` / `.tfvars` がある
- 対応:
  - `terraform fmt -recursive` を実行する
  - 差分を確認して意図しない変更がないかを見る

### 6.3 `terraform validate` が失敗する
- 主な原因:
  - 変数や resource 名の参照ミス
  - 型不一致
  - HCL 構文エラー
- 対応:
  - エラーに出たファイルと行を修正する
  - `fmt` 済みであることを確認して再実行する

### 6.4 `terraform plan` が失敗する
- 主な原因:
  - AWS 認証が通っていない
  - tfvars の値不足
  - 既存リソース読込権限不足
- 対応:
  - `aws sts get-caller-identity` で認証状態を確認する
  - `envs/dev.tfvars` の値を見直す
  - 読み取り権限不足なら実行主体の IAM 権限を確認する

## 7. Definition of Done
- `init`、`fmt -check`、`validate`、`plan` の目的が記載されている
- 実行順が明記されている
- 成功条件が記載されている
- `plan` はユーザー実行であることが明記されている
- 補助スクリプトの使い方が記載されている
