SELECT count(*) AS matched_count
FROM __TABLE_NAME__
WHERE (
        (year = '2026' AND month = '03' AND day BETWEEN '16' AND '31')
     OR (year = '2026' AND month = '04' AND day BETWEEN '01' AND '14')
      );
