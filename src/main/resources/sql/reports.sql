-- ============================================================================
-- Reporting queries used by the Java report/ETL layer.
-- These are loaded by name (delimited by "-- name: <id>") at runtime.
--
-- Snowflake dialect. Migrated from the Oracle originals per docs/MIGRATION.md:
-- CONNECT BY -> WITH RECURSIVE, ROWNUM -> QUALIFY, DECODE -> CASE,
-- NVL/NVL2 -> COALESCE/IFF, SYSDATE -> CURRENT_TIMESTAMP(),
-- ADD_MONTHS -> DATEADD, TO_CHAR -> TO_VARCHAR, no FROM dual.
-- ============================================================================

-- name: agent_org_chart
-- Recursive CTE replaces CONNECT BY / LEVEL / SYS_CONNECT_BY_PATH.
-- ORDER SIBLINGS BY is approximated by ordering on the built path.
WITH RECURSIVE org AS (
  SELECT a.agent_id,
         a.agent_name,
         a.manager_id,
         1                       AS depth,
         ' > ' || a.agent_name   AS path
    FROM hartford.agent a
   WHERE a.manager_id IS NULL
  UNION ALL
  SELECT a.agent_id,
         a.agent_name,
         a.manager_id,
         org.depth + 1,
         org.path || ' > ' || a.agent_name
    FROM hartford.agent a
    JOIN org
      ON a.manager_id = org.agent_id
)
SELECT LPAD(' ', 2 * (depth - 1)) || agent_name AS org_line,
       agent_id,
       manager_id,
       depth,
       path
  FROM org
 ORDER BY path;

-- name: monthly_premium
-- TO_VARCHAR / CASE / COALESCE / DATEADD replace TO_CHAR / DECODE / NVL / ADD_MONTHS.
SELECT TO_VARCHAR(p.effective_date, 'YYYY-MM')          AS ym,
       p.product_code,
       CASE p.status WHEN 'ACTIVE' THEN 'Y' ELSE 'N' END AS is_active,
       COUNT(*)                                          AS policy_count,
       SUM(COALESCE(p.annual_premium, 0))                AS gross_premium
  FROM hartford.policy p
 WHERE p.effective_date >= DATEADD('month', -24, CURRENT_TIMESTAMP())
 GROUP BY TO_VARCHAR(p.effective_date, 'YYYY-MM'), p.product_code,
          CASE p.status WHEN 'ACTIVE' THEN 'Y' ELSE 'N' END
 ORDER BY ym;

-- name: stale_open_claims
-- QUALIFY ROW_NUMBER() replaces ROWNUM paging; DATEDIFF/DATEADD replace
-- SYSDATE arithmetic.
SELECT cl.claim_id,
       cl.claim_number,
       cl.policy_id,
       cl.status,
       DATEDIFF('day', cl.reported_date, CURRENT_TIMESTAMP()) AS days_open,
       cl.reserve_amount
  FROM hartford.claim cl
 WHERE cl.status IN ('OPEN', 'INVESTIGATING')
   AND cl.reported_date < DATEADD('day', -30, CURRENT_TIMESTAMP())
QUALIFY ROW_NUMBER() OVER (ORDER BY cl.reported_date ASC) <= 100;

-- name: customer_upsert
-- MERGE without FROM dual; positional ? binds via the JDBC driver;
-- updated_ts maintained by the statement (no row triggers in Snowflake).
MERGE INTO hartford.customer tgt
USING (SELECT ? AS customer_id, ? AS first_name, ? AS last_name, ? AS email) src
   ON tgt.customer_id = src.customer_id
 WHEN MATCHED THEN
   UPDATE SET tgt.first_name = src.first_name,
              tgt.last_name  = src.last_name,
              tgt.email      = src.email,
              tgt.updated_ts = CURRENT_TIMESTAMP()
 WHEN NOT MATCHED THEN
   INSERT (customer_id, first_name, last_name, email)
   VALUES (src.customer_id, src.first_name, src.last_name, src.email);

-- name: high_risk_customers
-- IFF replaces NVL2; REGEXP_LIKE is supported (Snowflake anchors implicitly,
-- so the pattern matches the whole string unless wildcarded).
SELECT c.customer_id,
       c.first_name || ' ' || c.last_name AS full_name,
       c.risk_score,
       IFF(c.email IS NOT NULL, 'HAS_EMAIL', 'NO_EMAIL') AS email_flag,
       RANK() OVER (ORDER BY c.risk_score DESC) AS risk_rank
  FROM hartford.customer c
 WHERE c.risk_score > 0.6
   AND REGEXP_LIKE(c.phone, '860-.*')
 ORDER BY risk_rank;
