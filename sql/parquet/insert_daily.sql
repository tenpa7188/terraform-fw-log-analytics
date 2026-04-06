INSERT INTO fw_log_analytics.fortigate_logs_parquet
SELECT log_date,
       log_time,
       srcip,
       dstip,
       try_cast(srcport AS integer) AS srcport,
       try_cast(dstport AS integer) AS dstport,
       try_cast(proto AS integer) AS proto,
       action_raw,
       try_cast(policyid AS integer) AS policyid,
       year,
       month,
       day
FROM fw_log_analytics.fortigate_logs
WHERE year = '__YEAR__'
  AND month = '__MONTH__'
  AND day = '__DAY__'
  AND coalesce(trim(log_date), '') <> ''
  AND coalesce(trim(log_time), '') <> ''
  AND coalesce(trim(srcip), '') <> ''
  AND coalesce(trim(dstip), '') <> '';
