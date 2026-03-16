resource "aws_glue_catalog_database" "fw_log_analytics" {
  name        = "fw_log_analytics"
  description = "Glue Data Catalog database for firewall log analytics."
}

resource "aws_glue_catalog_table" "fortigate_logs" {
  name          = "fortigate_logs"
  database_name = aws_glue_catalog_database.fw_log_analytics.name
  table_type    = "EXTERNAL_TABLE"
  description   = "FortiGate-style firewall logs stored in S3 and queried by Athena."

  parameters = {
    EXTERNAL        = "TRUE"
    classification  = "text"
    compressionType = "gzip"
    typeOfData      = "file"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.log_bucket.bucket}/fortigate/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    compressed    = true

    ser_de_info {
      name                  = "fortigate-logs-regex-serde"
      serialization_library = "org.apache.hadoop.hive.serde2.RegexSerDe"
      parameters = {
        # Capture the required FortiGate fields anywhere in a key=value log line.
        "input.regex" = "^(?=(.*)$)(?=.*\\bdate=([^ ]+))(?=.*\\btime=([^ ]+))(?=.*\\bsrcip=([^ ]+))(?=.*\\bdstip=([^ ]+))(?:(?=.*\\bsrcport=([^ ]+)))?(?:(?=.*\\bdstport=([^ ]+)))?(?:(?=.*\\bproto=([^ ]+)))?(?:(?=.*\\baction=\\\"?([^\\\" ]+)\\\"?))?(?:(?=.*\\bpolicyid=([^ ]+)))?.*$"
      }
    }

    columns {
      name = "raw_line"
      type = "string"
    }

    columns {
      name = "log_date"
      type = "string"
    }

    columns {
      name = "log_time"
      type = "string"
    }

    columns {
      name = "srcip"
      type = "string"
    }

    columns {
      name = "dstip"
      type = "string"
    }

    columns {
      name = "srcport"
      type = "string"
    }

    columns {
      name = "dstport"
      type = "string"
    }

    columns {
      name = "proto"
      type = "string"
    }

    columns {
      name = "action_raw"
      type = "string"
    }

    columns {
      name = "policyid"
      type = "string"
    }
  }

  partition_keys {
    name = "year"
    type = "string"
  }

  partition_keys {
    name = "month"
    type = "string"
  }

  partition_keys {
    name = "day"
    type = "string"
  }
}
