from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import boto3


JST = ZoneInfo("Asia/Tokyo")
POLL_INTERVAL_SECONDS = 2
SQL_TEMPLATE_DIR = Path("sql") / "parquet"


@dataclass(frozen=True)
class AppConfig:
    # Lambda 環境変数から読み込む設定値をまとめる。
    # どの AWS リソースを使うかを 1 箇所で把握しやすくするための入れ物。
    athena_workgroup_name: str
    glue_database_name: str
    log_bucket_name: str
    lookback_days: int
    parquet_prefix_root: str
    parquet_table_name: str
    raw_prefix_root: str
    raw_table_name: str

    @classmethod
    def from_env(cls) -> "AppConfig":
        return cls(
            athena_workgroup_name=_require_env("ATHENA_ETL_WORKGROUP_NAME"),
            glue_database_name=_require_env("GLUE_DATABASE_NAME"),
            log_bucket_name=_require_env("LOG_BUCKET_NAME"),
            lookback_days=int(_require_env("LOOKBACK_DAYS")),
            parquet_prefix_root=_require_env("PARQUET_PREFIX_ROOT"),
            parquet_table_name=_require_env("PARQUET_TABLE_NAME"),
            raw_prefix_root=_require_env("RAW_PREFIX_ROOT"),
            raw_table_name=_require_env("RAW_TABLE_NAME"),
        )


def handler(event: dict[str, Any] | None, _context: Any) -> dict[str, Any]:
    # Lambda の入口。
    # mode に応じて対象日を決め、対象日ごとの ETL を順番に実行する。
    config = AppConfig.from_env()
    payload = event or {}
    mode = str(payload.get("mode", "daily")).strip().lower()

    if mode not in {"daily", "backfill", "rebuild"}:
        raise ValueError(f"Unsupported mode '{mode}'.")

    target_dates = _resolve_target_dates(mode=mode, payload=payload, lookback_days=config.lookback_days)
    athena = boto3.client("athena")
    s3 = boto3.client("s3")

    results: list[dict[str, Any]] = []

    for target_date in target_dates:
        try:
            # 日付単位で処理することで、どの日が失敗したかを切り分けやすくしている。
            result = _process_target_date(
                athena=athena,
                s3=s3,
                config=config,
                mode=mode,
                target_date=target_date,
            )
            results.append(result)
        except Exception as exc:
            failure = {
                "event_type": "parquet_etl_result",
                "mode": mode,
                "target_date": target_date.isoformat(),
                "status": "FAILED",
                "message": str(exc),
            }
            _log_structured(failure)
            raise

    summary = {
        "event_type": "parquet_etl_run_summary",
        "mode": mode,
        "status": "SUCCEEDED",
        "processed_dates": [item["target_date"] for item in results if item["status"] == "SUCCEEDED"],
        "skipped_dates": [item["target_date"] for item in results if item["status"] == "SKIPPED"],
        "result_count": len(results),
        "results": results,
    }
    _log_structured(summary)

    return {
        "statusCode": 200,
        "body": json.dumps(summary, ensure_ascii=True),
    }


def _process_target_date(
    *,
    athena: Any,
    s3: Any,
    config: AppConfig,
    mode: str,
    target_date: date,
) -> dict[str, Any]:
    # 1日分の ETL 本体。
    # 流れは次の通り。
    # 1. raw / parquet の存在確認
    # 2. quality summary 取得
    # 3. rebuild のときだけ parquet 削除
    # 4. insert_daily.sql 実行
    # 5. 結果を構造化ログとして出力
    raw_prefix = _date_prefix(config.raw_prefix_root, target_date)
    parquet_prefix = _date_prefix(config.parquet_prefix_root, target_date)

    raw_exists = _prefix_has_objects(s3=s3, bucket=config.log_bucket_name, prefix=raw_prefix)
    parquet_exists_before = _prefix_has_objects(s3=s3, bucket=config.log_bucket_name, prefix=parquet_prefix)

    base_result = {
        "event_type": "parquet_etl_result",
        "mode": mode,
        "target_date": target_date.isoformat(),
        "raw_prefix": raw_prefix,
        "parquet_prefix": parquet_prefix,
        "raw_exists": raw_exists,
        "parquet_exists_before": parquet_exists_before,
    }

    if not raw_exists:
        if mode == "daily":
            result = {
                **base_result,
                "status": "SKIPPED",
                "message": "raw data has not arrived yet",
            }
            _log_structured(result)
            return result

        raise RuntimeError(f"Raw data was not found for {target_date.isoformat()}.")

    if mode != "rebuild" and parquet_exists_before:
        result = {
            **base_result,
            "status": "SKIPPED",
            "message": "parquet data already exists for target date",
        }
        _log_structured(result)
        return result

    quality_sql = _render_sql(
        _load_sql_template("quality_summary_daily.sql"),
        target_date=target_date,
    )
    quality_query_id = _start_and_wait_athena_query(
        athena=athena,
        sql_text=quality_sql,
        database_name=config.glue_database_name,
        workgroup_name=config.athena_workgroup_name,
    )
    quality_summary = _get_quality_summary(athena=athena, query_execution_id=quality_query_id)

    deleted_object_count = 0
    if mode == "rebuild":
        # 削除前に、どの prefix を消す予定かをログに残す。
        # 誤った日付を再生成していないかを後で確認しやすくするため。
        _log_structured(
            {
                **base_result,
                "event_type": "parquet_etl_rebuild_delete_plan",
                "status": "DELETE_PENDING",
                "message": "deleting existing parquet prefix before rebuild",
            }
        )
        deleted_object_count = _delete_prefix_objects(
            s3=s3,
            bucket=config.log_bucket_name,
            prefix=parquet_prefix,
        )

    insert_sql = _render_sql(
        _load_sql_template("insert_daily.sql"),
        target_date=target_date,
    )
    insert_query_id = _start_and_wait_athena_query(
        athena=athena,
        sql_text=insert_sql,
        database_name=config.glue_database_name,
        workgroup_name=config.athena_workgroup_name,
    )
    parquet_exists_after = _prefix_has_objects(s3=s3, bucket=config.log_bucket_name, prefix=parquet_prefix)

    result = {
        **base_result,
        "status": "SUCCEEDED",
        "quality_summary_query_execution_id": quality_query_id,
        "insert_query_execution_id": insert_query_id,
        "deleted_object_count": deleted_object_count,
        "parquet_exists_after": parquet_exists_after,
        "quality_summary": quality_summary,
    }
    _log_structured(result)
    return result


def _resolve_target_dates(*, mode: str, payload: dict[str, Any], lookback_days: int) -> list[date]:
    # 実行 mode から対象日一覧を決める。
    # daily は直近 N 日を確認し、backfill / rebuild は明示指定日だけを対象にする。
    if mode == "daily":
        today_jst = datetime.now(JST).date()
        return [today_jst - timedelta(days=offset) for offset in range(1, lookback_days + 1)]

    target_date_raw = payload.get("target_date")
    if not isinstance(target_date_raw, str) or not target_date_raw.strip():
        raise ValueError(f"target_date is required for mode '{mode}'.")

    return [_parse_target_date(target_date_raw)]


def _parse_target_date(value: str) -> date:
    # 手動実行用の target_date を YYYY-MM-DD 形式で受け取り、date 型へ変換する。
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise ValueError(f"target_date must be YYYY-MM-DD, got '{value}'.") from exc


def _load_sql_template(filename: str) -> str:
    # SQL はコード埋め込みではなく別ファイル管理にしている。
    # これにより SQL 単体でレビューしやすくしている。
    for candidate in _sql_template_candidates(filename):
        if candidate.exists():
            return candidate.read_text(encoding="utf-8")

    tried = ", ".join(str(path) for path in _sql_template_candidates(filename))
    raise FileNotFoundError(f"SQL template '{filename}' was not found. Tried: {tried}")


def _sql_template_candidates(filename: str) -> list[Path]:
    # ローカル実行と Lambda 配布後の両方で SQL を見つけられるよう、候補を複数返す。
    current_dir = Path(__file__).resolve().parent
    return [
        current_dir / SQL_TEMPLATE_DIR / filename,
        current_dir.parents[1] / SQL_TEMPLATE_DIR / filename,
    ]


def _render_sql(sql_template: str, *, target_date: date) -> str:
    # SQL テンプレート中のプレースホルダを、対象日の値へ置き換える。
    return (
        sql_template.replace("__YEAR__", f"{target_date.year:04d}")
        .replace("__MONTH__", f"{target_date.month:02d}")
        .replace("__DAY__", f"{target_date.day:02d}")
    )


def _date_prefix(root_prefix: str, target_date: date) -> str:
    # raw / parquet 共通の year=YYYY/month=MM/day=DD 形式の prefix を組み立てる。
    return (
        f"{root_prefix}/"
        f"year={target_date.year:04d}/"
        f"month={target_date.month:02d}/"
        f"day={target_date.day:02d}/"
    )


def _prefix_has_objects(*, s3: Any, bucket: str, prefix: str) -> bool:
    # S3 prefix 配下にファイルが 1 つでもあるかを軽く確認する。
    # raw 到着済みか、parquet 作成済みかの判定に使う。
    response = s3.list_objects_v2(Bucket=bucket, Prefix=prefix, MaxKeys=1)
    return response.get("KeyCount", 0) > 0


def _delete_prefix_objects(*, s3: Any, bucket: str, prefix: str) -> int:
    # rebuild 用。
    # 対象日の parquet prefix だけを削除し、消した件数を返す。
    deleted_count = 0
    paginator = s3.get_paginator("list_objects_v2")

    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        contents = page.get("Contents", [])
        if not contents:
            continue

        objects = [{"Key": item["Key"]} for item in contents]
        s3.delete_objects(Bucket=bucket, Delete={"Objects": objects, "Quiet": True})
        deleted_count += len(objects)

    return deleted_count


def _start_and_wait_athena_query(
    *,
    athena: Any,
    sql_text: str,
    database_name: str,
    workgroup_name: str,
) -> str:
    # Athena クエリを開始し、完了するまでポーリングで待機する。
    # 今回は設計どおり、Lambda が完了待ちする A 案を採用している。
    start_response = athena.start_query_execution(
        QueryString=sql_text,
        QueryExecutionContext={"Database": database_name},
        WorkGroup=workgroup_name,
    )
    query_execution_id = start_response["QueryExecutionId"]

    while True:
        response = athena.get_query_execution(QueryExecutionId=query_execution_id)
        status = response["QueryExecution"]["Status"]["State"]

        if status == "SUCCEEDED":
            return query_execution_id

        if status in {"FAILED", "CANCELLED"}:
            reason = response["QueryExecution"]["Status"].get("StateChangeReason", "unknown")
            raise RuntimeError(f"Athena query {query_execution_id} ended with {status}: {reason}")

        time.sleep(POLL_INTERVAL_SECONDS)


def _get_quality_summary(*, athena: Any, query_execution_id: str) -> dict[str, Any]:
    # quality_summary_daily.sql の 1 行結果を dict に変換する。
    # CloudWatch Logs に載せやすい形へ整える役割。
    response = athena.get_query_results(QueryExecutionId=query_execution_id)
    rows = response["ResultSet"]["Rows"]

    if len(rows) < 2:
        raise RuntimeError(f"Quality summary query {query_execution_id} returned no data rows.")

    headers = _row_to_values(rows[0])
    values = _row_to_values(rows[1])
    record = dict(zip(headers, values))

    return {
        "target_year": record["target_year"],
        "target_month": record["target_month"],
        "target_day": record["target_day"],
        "raw_total_count": _to_int(record["raw_total_count"]),
        "reject_count": _to_int(record["reject_count"]),
        "insert_candidate_count": _to_int(record["insert_candidate_count"]),
        "missing_srcport_count": _to_int(record["missing_srcport_count"]),
        "invalid_srcport_count": _to_int(record["invalid_srcport_count"]),
        "missing_dstport_count": _to_int(record["missing_dstport_count"]),
        "invalid_dstport_count": _to_int(record["invalid_dstport_count"]),
        "missing_proto_count": _to_int(record["missing_proto_count"]),
        "invalid_proto_count": _to_int(record["invalid_proto_count"]),
        "missing_policyid_count": _to_int(record["missing_policyid_count"]),
        "invalid_policyid_count": _to_int(record["invalid_policyid_count"]),
        "warning_count": _to_int(record["warning_count"]),
    }


def _row_to_values(row: dict[str, Any]) -> list[str]:
    # Athena の ResultSet 1 行を単純な値リストに変換する。
    return [item.get("VarCharValue", "") for item in row["Data"]]


def _to_int(value: str) -> int:
    # Athena 結果は文字列で返るため、件数系を int に寄せる。
    return int(value) if value else 0


def _log_structured(payload: dict[str, Any]) -> None:
    # CloudWatch Logs で検索しやすいよう、JSON 1 行で出力する。
    print(json.dumps(payload, ensure_ascii=True, sort_keys=True))


def _require_env(name: str) -> str:
    # 必須の環境変数が欠けている場合は早めに止める。
    value = os.environ.get(name)
    if value is None or value == "":
        raise RuntimeError(f"Required environment variable '{name}' is not set.")
    return value
