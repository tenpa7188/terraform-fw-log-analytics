# Terraform Destroy Policy

## 1. 目的
- `terraform destroy` を安全に実行するための判断基準と手順を定義する。
- 検証環境を削除できる一方で、ログの誤削除を防ぐ。

## 2. 基本方針
- **`terraform destroy` はユーザーが明示的に実行する。**
- 日常運用で定期実行しない。
- 検証終了時、再構築前のクリーンアップ時など、目的が明確な場合のみ実行する。

## 3. 誤削除防止方針

### 3.1 S3 バケットは保護寄りに運用する
- 本プロジェクトの S3 バケットは `force_destroy = false` を前提とする。
- 意味:
  - バケット内にオブジェクトが残っている場合、`terraform destroy` だけでは削除されない。
- 意図:
  - FortiGate ログや Athena 結果の誤削除を防ぐため。

### 3.2 destroy 前に削除対象を確認する
- 対象環境が `dev` か `prod` か確認する。
- 認証先 AWS アカウントを確認する。
- S3 バケット内に保全すべきログが残っていないか確認する。
- Athena / Glue / IAM の削除影響を確認する。

### 3.3 本番相当環境では慎重に扱う
- `prod` 相当では、原則として `destroy` を常用しない。
- 本番削除が必要な場合は、事前に保全手順と承認を取る。

## 4. destroy 実行前チェックリスト
- 実行対象の AWS アカウントは正しいか
- 実行対象の tfvars は正しいか
- S3 バケット内のログは退避済み、または不要と判断済みか
- `force_destroy = false` により、S3 オブジェクトが残っていると destroy が失敗することを理解しているか
- 必要なら `terraform output` の値を記録したか

## 5. 実行手順

### 5.1 `terraform destroy`
```powershell
terraform destroy -var-file="envs/dev.tfvars"
```

- 何のために実行するか:
  - 検証環境の Terraform 管理リソースを削除するため
- どこで実行するか:
  - `terraform/`
- 何が起こるか:
  - Terraform state に載っている AWS リソースの削除を試みる
- 成功条件:
  - 削除対象が正常に消え、完了メッセージが表示される

### 5.2 S3 オブジェクトが残っていて失敗した場合
- `force_destroy = false` のため、バケット内にオブジェクトがあると削除できない。
- その場合は次の順で対応する。
1. バケット名を確認する
2. 必要ならログを退避する
3. バケット内オブジェクトを削除する
4. `terraform destroy -var-file="envs/dev.tfvars"` を再実行する

## 6. 削除失敗時の一次対応

### 6.1 S3 バケット削除で失敗する
- 主な原因:
  - バケット内にログや Athena 結果が残っている
- 対応:
  - オブジェクトを空にしてから再実行する

### 6.2 AccessDenied で失敗する
- 主な原因:
  - 実行主体の IAM 権限不足
  - 想定外アカウントで実行している
- 対応:
  - `aws sts get-caller-identity` で認証先を確認する
  - Terraform 実行権限を確認する

### 6.3 想定外の差分が見える
- 主な原因:
  - tfvars の選択ミス
  - state と実環境の不整合
- 対応:
  - 実行前に対象環境を見直す
  - 破壊的変更前に state と outputs を確認する

## 7. 関連資料
- [README.md](../README.md)
- [Terraform Validation Runbook](terraform-validation.md)
