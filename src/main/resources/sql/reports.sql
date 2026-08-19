-- ============================================================================
-- Reporting queries used by the Java report/ETL layer.
-- These are loaded by name (delimited by "-- name: <id>") at runtime.
--
-- Snowflake dialect (migrated from Oracle 19c). See docs/MIGRATION.md for the
-- construct-by-construct mapping.
-- ============================================================================

-- name: agent_org_chart
-- CONNECT BY / LEVEL / SYS_CONNECT_BY_PATH rewritten as a recursive CTE.
WITH RECURSIVE org AS (
    SELECT a.agent_id,
           a.manager_id,
           a.agent_name,
           1                                    AS depth,
           ' > ' || a.agent_name                AS path
      FROM hartford.claims.agent a
     WHERE a.manager_id IS NULL
    UNION ALL
    SELECT c.agent_id,
           c.manager_id,
           c.agent_name,
           p.depth + 1                          AS depth,
           p.path || ' > ' || c.agent_name      AS path
      FROM hartford.claims.agent c
      JOIN org p
        ON c.manager_id = p.agent_id
)
SELECT LPAD(' ', 2 * (depth - 1), ' ') || agent_name AS org_line,
       agent_id,
       manager_id,
       depth,
       path
  FROM org
 ORDER BY path;

-- name: monthly_premium
-- TO_CHAR -> TO_VARCHAR, DECODE -> CASE, NVL -> COALESCE, ADD_MONTHS -> DATEADD.
SELECT TO_VARCHAR(p.effective_date, 'YYYY-MM')                  AS ym,
       p.product_code,
       CASE WHEN p.status = 'ACTIVE' THEN 'Y' ELSE 'N' END       AS is_active,
       COUNT(*)                                                  AS policy_count,
       SUM(COALESCE(p.annual_premium, 0))                        AS gross_premium
  FROM hartford.claims.policy p
 WHERE p.effective_date >= DATEADD('month', -24, CURRENT_TIMESTAMP())
 GROUP BY TO_VARCHAR(p.effective_date, 'YYYY-MM'), p.product_code,
          CASE WHEN p.status = 'ACTIVE' THEN 'Y' ELSE 'N' END
 ORDER BY ym;

-- name: stale_open_claims
-- ROWNUM -> QUALIFY; SYSDATE arithmetic -> DATEDIFF / DATEADD.
SELECT cl.claim_id,
       cl.claim_number,
       cl.policy_id,
       cl.status,
       DATEDIFF('day', cl.reported_date, CURRENT_TIMESTAMP()) AS days_open,
       cl.reserve_amount
  FROM hartford.claims.claim cl
 WHERE cl.status IN ('OPEN', 'INVESTIGATING')
   AND cl.reported_date < DATEADD('day', -30, CURRENT_TIMESTAMP())
QUALIFY ROW_NUMBER() OVER (ORDER BY cl.reported_date ASC) <= 100
 ORDER BY cl.reported_date ASC;

-- name: customer_upsert
-- MERGE retained; the USING subquery no longer selects FROM dual and the binds
-- are driver-standard positional "?" placeholders.
MERGE INTO hartford.claims.customer tgt
USING (SELECT ?::NUMBER(12)   AS customer_id,
              ?::VARCHAR(60)  AS first_name,
              ?::VARCHAR(60)  AS last_name,
              ?::VARCHAR(120) AS email) src
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
-- NVL2 -> IFF. REGEXP_LIKE is supported but implicitly anchors the whole value,
-- so Oracle's '^860-' prefix match becomes '860-.*'.
SELECT c.customer_id,
       c.first_name || ' ' || c.last_name       AS full_name,
       c.risk_score,
       IFF(c.email IS NOT NULL, 'HAS_EMAIL', 'NO_EMAIL') AS email_flag,
       RANK() OVER (ORDER BY c.risk_score DESC) AS risk_rank
  FROM hartford.claims.customer c
 WHERE c.risk_score > 0.6
   AND REGEXP_LIKE(c.phone, '860-.*')
 ORDER BY risk_rank;

-- name: claim_cdc_delta
-- Replaces the Oracle "reported_date >= TRUNC(SYSDATE) - 1" scan used by the
-- nightly extract. The Stream in db/snowflake/04_streams_tasks.sql is the
-- primary CDC path; this DATEADD window is the reload/backfill fallback.
SELECT cl.claim_id,
       cl.claim_number,
       cl.policy_id,
       TO_VARCHAR(cl.reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported,
       cl.status,
       cl.reserve_amount,
       cl.paid_amount
  FROM hartford.claims.claim cl
 WHERE cl.reported_date >= DATEADD('day', -1, DATE_TRUNC('DAY', CURRENT_TIMESTAMP()))
 ORDER BY cl.claim_id;
