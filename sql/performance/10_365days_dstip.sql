SELECT count(*) AS matched_count
FROM __TABLE_NAME__
WHERE (
        (year = '2026' AND month = '03' AND day BETWEEN '16' AND '31')
     OR (year = '2026' AND month = '04')
     OR (year = '2026' AND month = '05')
     OR (year = '2026' AND month = '06')
     OR (year = '2026' AND month = '07')
     OR (year = '2026' AND month = '08')
     OR (year = '2026' AND month = '09')
     OR (year = '2026' AND month = '10')
     OR (year = '2026' AND month = '11')
     OR (year = '2026' AND month = '12')
     OR (year = '2027' AND month = '01')
     OR (year = '2027' AND month = '02')
     OR (year = '2027' AND month = '03' AND day BETWEEN '01' AND '15')
      )
  AND dstip = '61.205.120.130';
