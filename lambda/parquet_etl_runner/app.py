import json
import os
from typing import Any


def handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    """Placeholder handler until the Athena ETL implementation is added."""

    body = {
        "message": "Parquet ETL placeholder deployed.",
        "event": event,
        "config": {
            "glue_database_name": os.environ.get("GLUE_DATABASE_NAME"),
            "raw_table_name": os.environ.get("RAW_TABLE_NAME"),
            "parquet_table_name": os.environ.get("PARQUET_TABLE_NAME"),
            "athena_etl_workgroup_name": os.environ.get("ATHENA_ETL_WORKGROUP_NAME"),
            "log_bucket_name": os.environ.get("LOG_BUCKET_NAME"),
            "lookback_days": os.environ.get("LOOKBACK_DAYS"),
        },
    }

    return {
        "statusCode": 200,
        "body": json.dumps(body, ensure_ascii=True),
    }
