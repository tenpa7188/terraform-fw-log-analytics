WITH base AS (
  SELECT log_date,
         log_time,
         srcip,
         dstip,
         srcport,
         dstport,
         proto,
         policyid,
         year,
         month,
         day,
         CASE
           WHEN coalesce(trim(log_date), '') = '' THEN true
           WHEN coalesce(trim(log_time), '') = '' THEN true
           WHEN coalesce(trim(srcip), '') = '' THEN true
           WHEN coalesce(trim(dstip), '') = '' THEN true
           ELSE false
         END AS is_reject,
         CASE
           WHEN coalesce(trim(srcport), '') = '' THEN true
           ELSE false
         END AS missing_srcport,
         CASE
           WHEN coalesce(trim(srcport), '') <> ''
             AND try_cast(srcport AS integer) IS NULL THEN true
           ELSE false
         END AS invalid_srcport,
         CASE
           WHEN coalesce(trim(dstport), '') = '' THEN true
           ELSE false
         END AS missing_dstport,
         CASE
           WHEN coalesce(trim(dstport), '') <> ''
             AND try_cast(dstport AS integer) IS NULL THEN true
           ELSE false
         END AS invalid_dstport,
         CASE
           WHEN coalesce(trim(proto), '') = '' THEN true
           ELSE false
         END AS missing_proto,
         CASE
           WHEN coalesce(trim(proto), '') <> ''
             AND try_cast(proto AS integer) IS NULL THEN true
           ELSE false
         END AS invalid_proto,
         CASE
           WHEN coalesce(trim(policyid), '') = '' THEN true
           ELSE false
         END AS missing_policyid,
         CASE
           WHEN coalesce(trim(policyid), '') <> ''
             AND try_cast(policyid AS integer) IS NULL THEN true
           ELSE false
         END AS invalid_policyid
  FROM fw_log_analytics.fortigate_logs
  WHERE year = '__YEAR__'
    AND month = '__MONTH__'
    AND day = '__DAY__'
)
SELECT '__YEAR__' AS target_year,
       '__MONTH__' AS target_month,
       '__DAY__' AS target_day,
       count(*) AS raw_total_count,
       sum(CASE WHEN is_reject THEN 1 ELSE 0 END) AS reject_count,
       sum(CASE WHEN NOT is_reject THEN 1 ELSE 0 END) AS insert_candidate_count,
       sum(CASE WHEN missing_srcport THEN 1 ELSE 0 END) AS missing_srcport_count,
       sum(CASE WHEN invalid_srcport THEN 1 ELSE 0 END) AS invalid_srcport_count,
       sum(CASE WHEN missing_dstport THEN 1 ELSE 0 END) AS missing_dstport_count,
       sum(CASE WHEN invalid_dstport THEN 1 ELSE 0 END) AS invalid_dstport_count,
       sum(CASE WHEN missing_proto THEN 1 ELSE 0 END) AS missing_proto_count,
       sum(CASE WHEN invalid_proto THEN 1 ELSE 0 END) AS invalid_proto_count,
       sum(CASE WHEN missing_policyid THEN 1 ELSE 0 END) AS missing_policyid_count,
       sum(CASE WHEN invalid_policyid THEN 1 ELSE 0 END) AS invalid_policyid_count,
       sum(
         CASE
           WHEN NOT is_reject
             AND (
               missing_srcport
               OR missing_dstport
               OR missing_proto
               OR missing_policyid
               OR
               invalid_srcport
               OR invalid_dstport
               OR invalid_proto
               OR invalid_policyid
             ) THEN 1
           ELSE 0
         END
       ) AS warning_count
FROM base;
