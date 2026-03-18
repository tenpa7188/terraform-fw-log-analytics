#!/usr/bin/env bash
set -euo pipefail

# Upload rotated FortiGate traffic log archives to S3 by first assuming the ingest role.
# Optional Glue partition registration can be enabled to avoid manual ALTER TABLE work.
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
#   S3_PREFIX_ROOT                 Default: fortigate
#   SESSION_NAME                   Default: fortigate-log-upload
#   ASSUME_ROLE_DURATION_SECONDS   Default: 3600
#   MFA_SERIAL_NUMBER              MFA device ARN for the source identity
#   MFA_TOKEN_CODE                 6-digit MFA code. Required if MFA_SERIAL_NUMBER is set.
#   ENABLE_GLUE_PARTITION_ADD      Default: true
#   GLUE_DATABASE                  Default: fw_log_analytics
#   GLUE_TABLE                     Default: fortigate_logs
#   PYTHON_BIN                     Default: python3

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
S3_PREFIX_ROOT="${S3_PREFIX_ROOT:-fortigate}"
SESSION_NAME="${SESSION_NAME:-fortigate-log-upload}"
ASSUME_ROLE_DURATION_SECONDS="${ASSUME_ROLE_DURATION_SECONDS:-3600}"
ENABLE_GLUE_PARTITION_ADD="${ENABLE_GLUE_PARTITION_ADD:-true}"
GLUE_DATABASE="${GLUE_DATABASE:-fw_log_analytics}"
GLUE_TABLE="${GLUE_TABLE:-fortigate_logs}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

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

if [[ "${ENABLE_GLUE_PARTITION_ADD}" == "true" ]] && ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  echo "PYTHON_BIN '${PYTHON_BIN}' was not found. Install Python 3 or set PYTHON_BIN." >&2
  exit 1
fi

mkdir -p "${UPLOADED_DIR}"

TEMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

assume_role() {
  local assume_role_args=(
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

  aws "${assume_role_args[@]}"
}

build_partition_input_file() {
  local access_key_id="$1"
  local secret_access_key="$2"
  local session_token="$3"
  local year="$4"
  local month="$5"
  local day="$6"
  local storage_descriptor_file="${TEMP_DIR}/glue-storage-descriptor.json"
  local partition_input_file="${TEMP_DIR}/partition-${year}${month}${day}.json"
  local partition_location="s3://${BUCKET_NAME}/${S3_PREFIX_ROOT}/year=${year}/month=${month}/day=${day}/"

  if [[ ! -f "${storage_descriptor_file}" ]]; then
    AWS_ACCESS_KEY_ID="${access_key_id}" \
    AWS_SECRET_ACCESS_KEY="${secret_access_key}" \
    AWS_SESSION_TOKEN="${session_token}" \
    aws --region "${AWS_REGION}" \
      glue get-table \
      --database-name "${GLUE_DATABASE}" \
      --name "${GLUE_TABLE}" \
      --query "Table.StorageDescriptor" \
      --output json > "${storage_descriptor_file}"
  fi

  STORAGE_DESCRIPTOR_FILE="${storage_descriptor_file}" \
  PARTITION_INPUT_FILE="${partition_input_file}" \
  PARTITION_LOCATION="${partition_location}" \
  PARTITION_YEAR="${year}" \
  PARTITION_MONTH="${month}" \
  PARTITION_DAY="${day}" \
  "${PYTHON_BIN}" - <<'PY'
import json
import os


def prune(value):
    if isinstance(value, dict):
        result = {}
        for key, child in value.items():
            if child is None:
                continue
            result[key] = prune(child)
        return result
    if isinstance(value, list):
        return [prune(child) for child in value]
    return value


with open(os.environ["STORAGE_DESCRIPTOR_FILE"], encoding="utf-8") as handle:
    storage_descriptor = json.load(handle)

storage_descriptor["Location"] = os.environ["PARTITION_LOCATION"]
storage_descriptor = prune(storage_descriptor)

partition_input = [
    {
        "Values": [
            os.environ["PARTITION_YEAR"],
            os.environ["PARTITION_MONTH"],
            os.environ["PARTITION_DAY"],
        ],
        "StorageDescriptor": storage_descriptor,
    }
]

with open(os.environ["PARTITION_INPUT_FILE"], "w", encoding="utf-8") as handle:
    json.dump(partition_input, handle)
PY

  printf '%s\n' "${partition_input_file}"
}

register_glue_partition() {
  local access_key_id="$1"
  local secret_access_key="$2"
  local session_token="$3"
  local year="$4"
  local month="$5"
  local day="$6"
  local partition_input_file
  local response_file="${TEMP_DIR}/batch-create-${year}${month}${day}.json"
  local error_code
  local error_message

  partition_input_file="$(build_partition_input_file "${access_key_id}" "${secret_access_key}" "${session_token}" "${year}" "${month}" "${day}")"

  AWS_ACCESS_KEY_ID="${access_key_id}" \
  AWS_SECRET_ACCESS_KEY="${secret_access_key}" \
  AWS_SESSION_TOKEN="${session_token}" \
  aws --region "${AWS_REGION}" \
    glue batch-create-partition \
    --database-name "${GLUE_DATABASE}" \
    --table-name "${GLUE_TABLE}" \
    --partition-input-list "file://${partition_input_file}" \
    --output json > "${response_file}"

  IFS=$'\n' read -r error_code error_message < <(
    RESPONSE_FILE="${response_file}" \
    "${PYTHON_BIN}" - <<'PY'
import json
import os

with open(os.environ["RESPONSE_FILE"], encoding="utf-8") as handle:
    response = json.load(handle)

errors = response.get("Errors") or []

if not errors:
    print("NONE")
    print("")
else:
    detail = errors[0].get("ErrorDetail") or {}
    print(detail.get("ErrorCode", ""))
    print(detail.get("ErrorMessage", ""))
PY
  )

  if [[ -z "${error_code}" || "${error_code}" == "NONE" ]]; then
    echo "Registered Glue partition year=${year}/month=${month}/day=${day}."
    return 0
  fi

  if [[ "${error_code}" == "AlreadyExistsException" ]]; then
    echo "Glue partition already exists for year=${year}/month=${month}/day=${day}."
    return 0
  fi

  echo "Failed to register Glue partition year=${year}/month=${month}/day=${day}." >&2
  if [[ -n "${error_message}" ]]; then
    echo "${error_message}" >&2
  fi
  return 1
}

read -r access_key_id secret_access_key session_token expiration < <(assume_role)

if [[ -z "${access_key_id}" || -z "${secret_access_key}" || -z "${session_token}" ]]; then
  echo "Failed to acquire temporary credentials via sts:AssumeRole." >&2
  exit 1
fi

echo "Assumed role until ${expiration}."

shopt -s nullglob
declare -A registered_partitions=()

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
  s3_key="${S3_PREFIX_ROOT}/year=${year}/month=${month}/day=${day}/fortigate-${ymd}.log.gz"

  AWS_ACCESS_KEY_ID="${access_key_id}" \
  AWS_SECRET_ACCESS_KEY="${secret_access_key}" \
  AWS_SESSION_TOKEN="${session_token}" \
  aws --region "${AWS_REGION}" \
    s3 cp "${file}" "s3://${BUCKET_NAME}/${s3_key}" --only-show-errors

  partition_key="${year}-${month}-${day}"
  if [[ "${ENABLE_GLUE_PARTITION_ADD}" == "true" && -z "${registered_partitions[${partition_key}]:-}" ]]; then
    register_glue_partition "${access_key_id}" "${secret_access_key}" "${session_token}" "${year}" "${month}" "${day}"
    registered_partitions["${partition_key}"]=1
  fi

  mv "${file}" "${UPLOADED_DIR}/"
  echo "Uploaded ${base_name} to s3://${BUCKET_NAME}/${s3_key}"
done
