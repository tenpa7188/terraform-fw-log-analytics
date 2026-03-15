#!/usr/bin/env bash
set -euo pipefail

# Upload rotated FortiGate log archives to S3 by first assuming the ingest role.
#
# Required configuration file variables:
#   BUCKET_NAME      S3 bucket name, for example: fw-log-analytics-dev-xxxxxxxx
#   ROLE_ARN         IAM role ARN to assume, for example: arn:aws:iam::123456789012:role/fw-log-analytics-dev-ingest-role
#
# Optional environment variables:
#   CONFIG_FILE                    Default: /etc/default/fortigate-uploader
#   AWS_REGION                     Default: ap-northeast-1
#   SOURCE_PROFILE                 AWS CLI profile used as the caller for sts:AssumeRole
#   SOURCE_DIR                     Default: /var/log/fortigate
#   UPLOADED_DIR                   Default: /var/log/fortigate/uploaded
#   SESSION_NAME                   Default: fortigate-log-upload
#   ASSUME_ROLE_DURATION_SECONDS   Default: 3600
#   MFA_SERIAL_NUMBER              MFA device ARN for the source identity
#   MFA_TOKEN_CODE                 6-digit MFA code. Required if MFA_SERIAL_NUMBER is set.

CONFIG_FILE="${CONFIG_FILE:-/etc/default/fortigate-uploader}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Configuration file not found: ${CONFIG_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "${CONFIG_FILE}"

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
SOURCE_DIR="${SOURCE_DIR:-/var/log/fortigate}"
UPLOADED_DIR="${UPLOADED_DIR:-/var/log/fortigate/uploaded}"
SESSION_NAME="${SESSION_NAME:-fortigate-log-upload}"
ASSUME_ROLE_DURATION_SECONDS="${ASSUME_ROLE_DURATION_SECONDS:-3600}"

if [[ -z "${BUCKET_NAME:-}" ]]; then
  echo "BUCKET_NAME is required." >&2
  exit 1
fi

if [[ -z "${ROLE_ARN:-}" ]]; then
  echo "ROLE_ARN is required." >&2
  exit 1
fi

if [[ -n "${MFA_SERIAL_NUMBER:-}" && -z "${MFA_TOKEN_CODE:-}" ]]; then
  echo "MFA_TOKEN_CODE is required when MFA_SERIAL_NUMBER is set." >&2
  exit 1
fi

mkdir -p "${UPLOADED_DIR}"

assume_role_args=(
  --region "${AWS_REGION}"
  sts assume-role
  --role-arn "${ROLE_ARN}"
  --role-session-name "${SESSION_NAME}"
  --duration-seconds "${ASSUME_ROLE_DURATION_SECONDS}"
  --query "Credentials.[AccessKeyId,SecretAccessKey,SessionToken,Expiration]"
  --output text
)

if [[ -n "${SOURCE_PROFILE:-}" ]]; then
  assume_role_args+=(--profile "${SOURCE_PROFILE}")
fi

if [[ -n "${MFA_SERIAL_NUMBER:-}" ]]; then
  assume_role_args+=(--serial-number "${MFA_SERIAL_NUMBER}" --token-code "${MFA_TOKEN_CODE}")
fi

read -r access_key_id secret_access_key session_token expiration < <(aws "${assume_role_args[@]}")

if [[ -z "${access_key_id}" || -z "${secret_access_key}" || -z "${session_token}" ]]; then
  echo "Failed to acquire temporary credentials via sts:AssumeRole." >&2
  exit 1
fi

echo "Assumed role until ${expiration}."

shopt -s nullglob

for file in "${SOURCE_DIR}"/incoming.log-*.gz; do
  base_name="$(basename "${file}")"
  ymd="${base_name#incoming.log-}"
  ymd="${ymd%.gz}"

  if [[ ! "${ymd}" =~ ^[0-9]{8}$ ]]; then
    echo "Skipping unexpected file name: ${base_name}" >&2
    continue
  fi

  year="${ymd:0:4}"
  month="${ymd:4:2}"
  day="${ymd:6:2}"
  s3_key="fortigate/year=${year}/month=${month}/day=${day}/fortigate-${ymd}.log.gz"

  AWS_ACCESS_KEY_ID="${access_key_id}" \
  AWS_SECRET_ACCESS_KEY="${secret_access_key}" \
  AWS_SESSION_TOKEN="${session_token}" \
  aws --region "${AWS_REGION}" \
    s3 cp "${file}" "s3://${BUCKET_NAME}/${s3_key}" --only-show-errors

  mv "${file}" "${UPLOADED_DIR}/"
  echo "Uploaded ${base_name} to s3://${BUCKET_NAME}/${s3_key}"
done
