-- ============================================================================
-- Reporting queries used by the Java report/ETL layer.
-- These are loaded by name (delimited by "-- name: <id>") at runtime.
--
-- Migrated to Snowflake: CONNECT BY -> WITH RECURSIVE, ROWNUM -> QUALIFY,
-- DECODE -> CASE, NVL -> COALESCE, NVL2 -> IFF, SYSDATE -> CURRENT_TIMESTAMP(),
-- ADD_MONTHS -> DATEADD, TO_CHAR -> TO_VARCHAR, date subtraction -> DATEDIFF,
-- and "FROM dual" dropped. See docs/MIGRATION.md section 5.
-- ============================================================================

-- name: agent_org_chart
-- Hierarchy via a recursive CTE: depth replaces LEVEL and the concatenated
-- path replaces SYS_CONNECT_BY_PATH.
WITH RECURSIVE org AS (
    SELECT a.agent_id,
           a.manager_id,
           a.agent_name,
           1            AS depth,
           a.agent_name AS path
      FROM hartford.claims.agent a
     WHERE a.manager_id IS NULL
    UNION ALL
    SELECT a.agent_id,
           a.manager_id,
           a.agent_name,
           o.depth + 1                     AS depth,
           o.path || ' > ' || a.agent_name AS path
      FROM hartford.claims.agent a
      JOIN org o
        ON a.manager_id = o.agent_id
)
SELECT LPAD(' ', 2 * (depth - 1), ' ') || agent_name AS org_line,
       agent_id,
       manager_id,
       depth,
       path
  FROM org
 ORDER BY path;

-- name: monthly_premium
SELECT TO_VARCHAR(p.effective_date, 'YYYY-MM')                    AS ym,
       p.product_code,
       CASE WHEN p.status = 'ACTIVE' THEN 'Y' ELSE 'N' END         AS is_active,
       COUNT(*)                                                   AS policy_count,
       SUM(COALESCE(p.annual_premium, 0))                         AS gross_premium
  FROM hartford.claims.policy p
 WHERE p.effective_date >= DATEADD('month', -24, CURRENT_TIMESTAMP())
 GROUP BY ym, p.product_code, is_active
 ORDER BY ym;

-- name: stale_open_claims
SELECT cl.claim_id,
       cl.claim_number,
       cl.policy_id,
       cl.status,
       DATEDIFF('day', cl.reported_date, CURRENT_TIMESTAMP()) AS days_open,
       cl.reserve_amount
  FROM hartford.claims.claim cl
 WHERE cl.status IN ('OPEN', 'INVESTIGATING')
   AND cl.reported_date < DATEADD('day', -30, CURRENT_TIMESTAMP())
QUALIFY ROW_NUMBER() OVER (ORDER BY cl.reported_date ASC) <= 100;

-- name: customer_upsert
-- MERGE without DUAL; binds stay positional (?) for the Snowflake JDBC driver.
MERGE INTO hartford.claims.customer tgt
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
       c.first_name || ' ' || c.last_name             AS full_name,
       c.risk_score,
       IFF(c.email IS NOT NULL, 'HAS_EMAIL', 'NO_EMAIL') AS email_flag,
       RANK() OVER (ORDER BY c.risk_score DESC)       AS risk_rank
  FROM hartford.claims.customer c
 WHERE c.risk_score > 0.6
   AND REGEXP_LIKE(c.phone, '860-.*')
 ORDER BY risk_rank;
