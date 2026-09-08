-- ============================================================================
-- Reporting queries used by the Java report/ETL layer (Snowflake dialect).
-- These are loaded by name (delimited by "-- name: <id>") at runtime.
--
-- Translated from the Oracle originals per docs/MIGRATION.md:
--   CONNECT BY -> WITH RECURSIVE, ROWNUM -> QUALIFY, DECODE -> CASE,
--   NVL -> COALESCE, NVL2 -> IFF, SYSDATE -> CURRENT_TIMESTAMP(),
--   ADD_MONTHS -> DATEADD, TO_CHAR -> TO_VARCHAR, FROM dual -> dropped.
-- Schema objects resolve against the session's current schema (HARTFORD.CLAIMS,
-- set via the JDBC URL).
-- ============================================================================

-- name: agent_org_chart
-- Recursive CTE replacing CONNECT BY / LEVEL / SYS_CONNECT_BY_PATH / ORDER SIBLINGS BY.
WITH RECURSIVE org AS (
    SELECT a.agent_id,
           a.manager_id,
           a.agent_name,
           1                                      AS depth,
           ' > ' || a.agent_name                  AS path
      FROM agent a
     WHERE a.manager_id IS NULL
    UNION ALL
    SELECT c.agent_id,
           c.manager_id,
           c.agent_name,
           o.depth + 1,
           o.path || ' > ' || c.agent_name
      FROM agent c
      JOIN org o
        ON c.manager_id = o.agent_id
)
SELECT REPEAT(' ', 2 * (depth - 1)) || agent_name AS org_line,
       agent_id,
       manager_id,
       depth,
       path
  FROM org
 ORDER BY path;   -- parents sort before their children, siblings by name

-- name: monthly_premium
SELECT TO_VARCHAR(p.effective_date, 'YYYY-MM')          AS ym,
       p.product_code,
       CASE WHEN p.status = 'ACTIVE' THEN 'Y' ELSE 'N' END AS is_active,
       COUNT(*)                                          AS policy_count,
       SUM(COALESCE(p.annual_premium, 0))                AS gross_premium
  FROM policy p
 WHERE p.effective_date >= DATEADD('month', -24, CURRENT_TIMESTAMP())
 GROUP BY TO_VARCHAR(p.effective_date, 'YYYY-MM'), p.product_code,
          CASE WHEN p.status = 'ACTIVE' THEN 'Y' ELSE 'N' END
 ORDER BY ym;

-- name: stale_open_claims
SELECT cl.claim_id,
       cl.claim_number,
       cl.policy_id,
       cl.status,
       DATEDIFF('day', cl.reported_date, CURRENT_TIMESTAMP()) AS days_open,
       cl.reserve_amount
  FROM claim cl
 WHERE cl.status IN ('OPEN', 'INVESTIGATING')
   AND cl.reported_date < DATEADD('day', -30, CURRENT_TIMESTAMP())
QUALIFY ROW_NUMBER() OVER (ORDER BY cl.reported_date ASC) <= 100
 ORDER BY cl.reported_date ASC;

-- name: customer_upsert
-- MERGE with JDBC positional binds (?) and no DUAL source.
MERGE INTO customer tgt
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
SELECT c.customer_id,
       c.first_name || ' ' || c.last_name AS full_name,
       c.risk_score,
       IFF(c.email IS NOT NULL, 'HAS_EMAIL', 'NO_EMAIL') AS email_flag,
       RANK() OVER (ORDER BY c.risk_score DESC) AS risk_rank
  FROM customer c
 WHERE c.risk_score > 0.6
   AND REGEXP_LIKE(c.phone, '^860-.*')
 ORDER BY risk_rank;

-- name: changed_claims_export
-- Nightly outbound feed: unload changed claims straight to the export stage
-- (replaces the SPOOL -> .psv -> SFTP hop). NightlyExtract substitutes {{run_date}}.
COPY INTO @claims_export/claims/{{run_date}}/changed_claims_
  FROM (
    SELECT cl.claim_id, cl.claim_number, cl.policy_id,
           TO_VARCHAR(cl.reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported,
           cl.status, cl.reserve_amount, cl.paid_amount
      FROM claim cl
     WHERE cl.reported_date >= DATEADD('day', -1, CURRENT_DATE())
     ORDER BY cl.claim_id
  )
  FILE_FORMAT = (FORMAT_NAME = ff_psv)
  OVERWRITE = TRUE
  SINGLE = TRUE
  HEADER = FALSE;
