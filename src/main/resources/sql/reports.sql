-- ============================================================================
-- Reporting queries used by the Java report/ETL layer.
-- These are loaded by name (delimited by "-- name: <id>") at runtime.
--
-- Snowflake dialect. Object names are unqualified and resolve against the
-- database/schema set on the connection (db.database / db.schema in
-- application.properties). See docs/MIGRATION.md for the Oracle originals.
-- ============================================================================

-- name: agent_org_chart
-- CONNECT BY -> recursive CTE; LEVEL -> depth; SYS_CONNECT_BY_PATH -> path;
-- ORDER SIBLINGS BY agent_name -> ORDER BY sort_key (CHR(1)-joined name path).
WITH RECURSIVE org (agent_id, manager_id, agent_name, depth, path, sort_key) AS (
  SELECT agent_id,
         manager_id,
         agent_name,
         1,
         CAST(' > ' || agent_name AS VARCHAR),
         CAST(agent_name AS VARCHAR)
    FROM agent
   WHERE manager_id IS NULL
  UNION ALL
  SELECT a.agent_id,
         a.manager_id,
         a.agent_name,
         o.depth + 1,
         o.path || ' > ' || a.agent_name,
         o.sort_key || CHR(1) || a.agent_name
    FROM agent a
    JOIN org o
      ON a.manager_id = o.agent_id
)
SELECT REPEAT(' ', 2 * (depth - 1)) || agent_name AS org_line,
       agent_id,
       manager_id,
       depth,
       path
  FROM org
 ORDER BY sort_key;

-- name: monthly_premium
-- TO_CHAR -> TO_VARCHAR, DECODE -> CASE, NVL -> COALESCE, ADD_MONTHS -> DATEADD.
SELECT TO_VARCHAR(p.effective_date, 'YYYY-MM')                 AS ym,
       p.product_code,
       CASE WHEN p.status = 'ACTIVE' THEN 'Y' ELSE 'N' END     AS is_active,
       COUNT(*)                                                AS policy_count,
       SUM(COALESCE(p.annual_premium, 0))                      AS gross_premium
  FROM policy p
 WHERE p.effective_date >= DATEADD('month', -24, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)
 GROUP BY ym, p.product_code, is_active
 ORDER BY ym;

-- name: stale_open_claims
-- ROWNUM -> LIMIT; SYSDATE - date (fractional days, rounded) -> seconds / 86400.
SELECT cl.claim_id,
       cl.claim_number,
       cl.policy_id,
       cl.status,
       ROUND(DATEDIFF('second', cl.reported_date, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ) / 86400) AS days_open,
       cl.reserve_amount
  FROM claim cl
 WHERE cl.status IN ('OPEN', 'INVESTIGATING')
   AND cl.reported_date < DATEADD('day', -30, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)
 ORDER BY cl.reported_date ASC
 LIMIT 100;

-- name: customer_upsert
-- MERGE ... USING (SELECT ... FROM dual) -> USING (SELECT ...) with JDBC ? binds.
-- updated_ts is set here because Snowflake has no row trigger to maintain it.
MERGE INTO customer tgt
USING (SELECT ?::NUMBER(12) AS customer_id,
              ?::VARCHAR    AS first_name,
              ?::VARCHAR    AS last_name,
              ?::VARCHAR    AS email) src
   ON tgt.customer_id = src.customer_id
 WHEN MATCHED THEN
   UPDATE SET first_name = src.first_name,
              last_name  = src.last_name,
              email      = src.email,
              updated_ts = CURRENT_TIMESTAMP()
 WHEN NOT MATCHED THEN
   INSERT (customer_id, first_name, last_name, email)
   VALUES (src.customer_id, src.first_name, src.last_name, src.email);

-- name: high_risk_customers
-- NVL2 -> IFF. Snowflake REGEXP_LIKE matches the whole string, so the
-- Oracle prefix pattern '^860-' becomes '860-.*'.
SELECT c.customer_id,
       COALESCE(c.first_name, '') || ' ' || COALESCE(c.last_name, '') AS full_name,
       c.risk_score,
       IFF(c.email IS NOT NULL, 'HAS_EMAIL', 'NO_EMAIL')            AS email_flag,
       RANK() OVER (ORDER BY c.risk_score DESC)                     AS risk_rank
  FROM customer c
 WHERE c.risk_score > 0.6
   AND REGEXP_LIKE(c.phone, '860-.*')
 ORDER BY risk_rank;
