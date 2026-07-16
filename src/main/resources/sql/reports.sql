-- ============================================================================
-- Reporting queries used by the Java report/ETL layer.
-- These are loaded by name (delimited by "-- name: <id>") at runtime.
--
-- MIGRATED to Snowflake SQL. Object references are unqualified and resolve in
-- the active schema (HARTFORD.CLAIMS, set via the JDBC URL / USE SCHEMA).
-- See docs/MIGRATION.md for the construct-by-construct mapping.
-- ============================================================================

-- name: agent_org_chart
-- Oracle CONNECT BY hierarchy -> Snowflake WITH RECURSIVE CTE.
-- LEVEL -> depth counter; SYS_CONNECT_BY_PATH -> path built in the CTE;
-- ORDER SIBLINGS BY -> ORDER BY the accumulated path.
WITH RECURSIVE org (agent_id, manager_id, agent_name, depth, path) AS (
    SELECT agent_id,
           manager_id,
           agent_name,
           1                  AS depth,
           agent_name         AS path
      FROM agent
     WHERE manager_id IS NULL
    UNION ALL
    SELECT a.agent_id,
           a.manager_id,
           a.agent_name,
           o.depth + 1        AS depth,
           o.path || ' > ' || a.agent_name AS path
      FROM agent a
      JOIN org o ON a.manager_id = o.agent_id
)
SELECT LPAD('', 2 * (depth - 1), ' ') || agent_name AS org_line,
       agent_id,
       manager_id,
       depth,
       path
  FROM org
 ORDER BY path;

-- name: monthly_premium
-- TO_CHAR -> TO_VARCHAR; DECODE -> CASE; NVL -> COALESCE;
-- ADD_MONTHS -> DATEADD; SYSDATE -> CURRENT_TIMESTAMP().
SELECT TO_VARCHAR(p.effective_date, 'YYYY-MM')            AS ym,
       p.product_code,
       CASE WHEN p.status = 'ACTIVE' THEN 'Y' ELSE 'N' END AS is_active,
       COUNT(*)                                           AS policy_count,
       SUM(COALESCE(p.annual_premium, 0))                 AS gross_premium
  FROM policy p
 WHERE p.effective_date >= DATEADD('month', -24, CURRENT_TIMESTAMP())
 GROUP BY TO_VARCHAR(p.effective_date, 'YYYY-MM'), p.product_code,
          CASE WHEN p.status = 'ACTIVE' THEN 'Y' ELSE 'N' END
 ORDER BY ym;

-- name: stale_open_claims
-- ROWNUM pagination -> QUALIFY ROW_NUMBER(); SYSDATE day-arithmetic -> DATEDIFF/DATEADD.
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
-- Oracle MERGE ... USING (SELECT ... FROM dual): drop FROM dual; positional
-- binds use ? (Snowflake JDBC) instead of :1..:4; SYSDATE -> CURRENT_TIMESTAMP().
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
-- NVL2 -> IFF; REGEXP_LIKE is full-match in Snowflake, so '^860-' becomes '860-.*'.
SELECT c.customer_id,
       c.first_name || ' ' || c.last_name AS full_name,
       c.risk_score,
       IFF(c.email IS NOT NULL, 'HAS_EMAIL', 'NO_EMAIL') AS email_flag,
       RANK() OVER (ORDER BY c.risk_score DESC) AS risk_rank
  FROM customer c
 WHERE c.risk_score > 0.6
   AND REGEXP_LIKE(c.phone, '860-.*')
 ORDER BY risk_rank;
