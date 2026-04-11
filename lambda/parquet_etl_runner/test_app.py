import sys
import types
import unittest
from datetime import date, datetime as real_datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import MagicMock, patch


CURRENT_DIR = Path(__file__).resolve().parent
if str(CURRENT_DIR) not in sys.path:
    sys.path.insert(0, str(CURRENT_DIR))

if "boto3" not in sys.modules:
    fake_boto3 = types.ModuleType("boto3")
    fake_boto3.client = MagicMock()
    sys.modules["boto3"] = fake_boto3

if "zoneinfo" not in sys.modules:
    fake_zoneinfo = types.ModuleType("zoneinfo")

    def _fake_zone_info(_name):
        return timezone(timedelta(hours=9))

    fake_zoneinfo.ZoneInfo = _fake_zone_info
    sys.modules["zoneinfo"] = fake_zoneinfo

import app as parquet_app


class FixedDateTime:
    @classmethod
    def now(cls, tz=None):
        return real_datetime(2026, 4, 8, 9, 0, 0, tzinfo=tz)


class ParquetEtlRunnerTests(unittest.TestCase):
    def setUp(self):
        self.config = parquet_app.AppConfig(
            athena_workgroup_name="fw-log-analytics-etl-wg",
            glue_database_name="fw_log_analytics",
            log_bucket_name="example-bucket",
            lookback_days=7,
            parquet_prefix_root="fortigate-parquet",
            parquet_table_name="fortigate_logs_parquet",
            raw_prefix_root="fortigate",
            raw_table_name="fortigate_logs",
        )

    def test_render_sql_replaces_date_placeholders(self):
        rendered = parquet_app._render_sql(
            "year='__YEAR__' month='__MONTH__' day='__DAY__'",
            target_date=date(2026, 4, 7),
        )

        self.assertEqual(rendered, "year='2026' month='04' day='07'")

    def test_resolve_target_dates_daily_returns_lookback_days(self):
        with patch.object(parquet_app, "datetime", FixedDateTime):
            target_dates = parquet_app._resolve_target_dates(
                mode="daily",
                payload={},
                lookback_days=3,
            )

        self.assertEqual(
            target_dates,
            [
                date(2026, 4, 7),
                date(2026, 4, 6),
                date(2026, 4, 5),
            ],
        )

    def test_resolve_target_dates_requires_target_date_for_backfill(self):
        with self.assertRaisesRegex(ValueError, "target_date is required"):
            parquet_app._resolve_target_dates(
                mode="backfill",
                payload={},
                lookback_days=7,
            )

    def test_process_target_date_skips_daily_when_raw_not_arrived(self):
        athena = MagicMock()
        s3 = MagicMock()

        with (
            patch.object(parquet_app, "_prefix_has_objects", side_effect=[False, False]),
            patch.object(parquet_app, "_log_structured") as log_mock,
        ):
            result = parquet_app._process_target_date(
                athena=athena,
                s3=s3,
                config=self.config,
                mode="daily",
                target_date=date(2026, 4, 7),
            )

        self.assertEqual(result["status"], "SKIPPED")
        self.assertEqual(result["message"], "raw data has not arrived yet")
        self.assertIn("timing_ms", result)
        self.assertIn("target_total_ms", result["timing_ms"])
        log_mock.assert_called_once()

    def test_process_target_date_skips_when_parquet_already_exists(self):
        athena = MagicMock()
        s3 = MagicMock()

        with (
            patch.object(parquet_app, "_prefix_has_objects", side_effect=[True, True]),
            patch.object(parquet_app, "_log_structured") as log_mock,
        ):
            result = parquet_app._process_target_date(
                athena=athena,
                s3=s3,
                config=self.config,
                mode="backfill",
                target_date=date(2026, 4, 7),
            )

        self.assertEqual(result["status"], "SKIPPED")
        self.assertEqual(result["message"], "parquet data already exists for target date")
        self.assertIn("timing_ms", result)
        self.assertIn("target_total_ms", result["timing_ms"])
        log_mock.assert_called_once()

    def test_process_target_date_rebuild_deletes_and_inserts(self):
        athena = MagicMock()
        s3 = MagicMock()
        quality_summary = {
            "target_year": "2026",
            "target_month": "04",
            "target_day": "07",
            "raw_total_count": 10,
            "reject_count": 1,
            "insert_candidate_count": 9,
            "missing_srcport_count": 1,
            "invalid_srcport_count": 0,
            "missing_dstport_count": 0,
            "invalid_dstport_count": 0,
            "missing_proto_count": 0,
            "invalid_proto_count": 0,
            "missing_policyid_count": 0,
            "invalid_policyid_count": 0,
            "warning_count": 1,
        }
        quality_query = {
            "query_execution_id": "quality-query",
            "wall_clock_ms": 1200,
            "total_execution_ms": 1100,
            "engine_execution_ms": 900,
            "query_queue_ms": 100,
            "data_scanned_bytes": 12345,
        }
        insert_query = {
            "query_execution_id": "insert-query",
            "wall_clock_ms": 2400,
            "total_execution_ms": 2300,
            "engine_execution_ms": 2100,
            "query_queue_ms": 150,
            "data_scanned_bytes": 67890,
        }

        with (
            patch.object(parquet_app, "_prefix_has_objects", side_effect=[True, True, True]),
            patch.object(parquet_app, "_load_sql_template", side_effect=["quality __YEAR__", "insert __YEAR__"]),
            patch.object(parquet_app, "_start_and_wait_athena_query", side_effect=[quality_query, insert_query]),
            patch.object(parquet_app, "_get_quality_summary", return_value=quality_summary),
            patch.object(parquet_app, "_delete_prefix_objects", return_value=3) as delete_mock,
            patch.object(parquet_app, "_log_structured") as log_mock,
        ):
            result = parquet_app._process_target_date(
                athena=athena,
                s3=s3,
                config=self.config,
                mode="rebuild",
                target_date=date(2026, 4, 7),
            )

        self.assertEqual(result["status"], "SUCCEEDED")
        self.assertEqual(result["deleted_object_count"], 3)
        self.assertEqual(result["quality_summary"], quality_summary)
        self.assertEqual(result["quality_summary_query_execution_id"], "quality-query")
        self.assertEqual(result["insert_query_execution_id"], "insert-query")
        self.assertEqual(result["quality_summary_query"], quality_query)
        self.assertEqual(result["insert_query"], insert_query)
        self.assertIn("timing_ms", result)
        self.assertIn("target_total_ms", result["timing_ms"])
        delete_mock.assert_called_once()
        self.assertEqual(log_mock.call_count, 2)

    def test_build_query_summary_extracts_athena_statistics(self):
        query_execution = {
            "QueryExecutionId": "query-123",
            "WorkGroup": "fw-log-analytics-etl-wg",
            "StatementType": "DML",
            "Status": {
                "State": "SUCCEEDED",
                "StateChangeReason": "",
            },
            "ResultConfiguration": {
                "OutputLocation": "s3://example-bucket/athena-results/etl/query-123.csv",
            },
            "Statistics": {
                "TotalExecutionTimeInMillis": 3100,
                "EngineExecutionTimeInMillis": 2500,
                "QueryQueueTimeInMillis": 300,
                "ServicePreProcessingTimeInMillis": 100,
                "ServiceProcessingTimeInMillis": 200,
                "QueryPlanningTimeInMillis": 400,
                "DataScannedInBytes": 987654,
            },
        }

        result = parquet_app._build_query_summary(
            query_execution=query_execution,
            wall_clock_ms=3200,
        )

        self.assertEqual(result["query_execution_id"], "query-123")
        self.assertEqual(result["workgroup_name"], "fw-log-analytics-etl-wg")
        self.assertEqual(result["wall_clock_ms"], 3200)
        self.assertEqual(result["total_execution_ms"], 3100)
        self.assertEqual(result["engine_execution_ms"], 2500)
        self.assertEqual(result["query_queue_ms"], 300)
        self.assertEqual(result["data_scanned_bytes"], 987654)

    def test_get_quality_summary_parses_athena_result_rows(self):
        athena = MagicMock()
        athena.get_query_results.return_value = {
            "ResultSet": {
                "Rows": [
                    {
                        "Data": [
                            {"VarCharValue": "target_year"},
                            {"VarCharValue": "target_month"},
                            {"VarCharValue": "target_day"},
                            {"VarCharValue": "raw_total_count"},
                            {"VarCharValue": "reject_count"},
                            {"VarCharValue": "insert_candidate_count"},
                            {"VarCharValue": "missing_srcport_count"},
                            {"VarCharValue": "invalid_srcport_count"},
                            {"VarCharValue": "missing_dstport_count"},
                            {"VarCharValue": "invalid_dstport_count"},
                            {"VarCharValue": "missing_proto_count"},
                            {"VarCharValue": "invalid_proto_count"},
                            {"VarCharValue": "missing_policyid_count"},
                            {"VarCharValue": "invalid_policyid_count"},
                            {"VarCharValue": "warning_count"},
                        ]
                    },
                    {
                        "Data": [
                            {"VarCharValue": "2026"},
                            {"VarCharValue": "04"},
                            {"VarCharValue": "07"},
                            {"VarCharValue": "100"},
                            {"VarCharValue": "2"},
                            {"VarCharValue": "98"},
                            {"VarCharValue": "3"},
                            {"VarCharValue": "1"},
                            {"VarCharValue": "4"},
                            {"VarCharValue": "0"},
                            {"VarCharValue": "5"},
                            {"VarCharValue": "1"},
                            {"VarCharValue": "6"},
                            {"VarCharValue": "0"},
                            {"VarCharValue": "20"},
                        ]
                    },
                ]
            }
        }

        result = parquet_app._get_quality_summary(
            athena=athena,
            query_execution_id="quality-query",
        )

        self.assertEqual(result["target_year"], "2026")
        self.assertEqual(result["raw_total_count"], 100)
        self.assertEqual(result["reject_count"], 2)
        self.assertEqual(result["warning_count"], 20)
        self.assertEqual(result["missing_policyid_count"], 6)


if __name__ == "__main__":
    unittest.main()
