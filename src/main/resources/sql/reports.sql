-- ============================================================================
-- Reporting queries used by the Java report/ETL layer (Snowflake dialect).
-- These are loaded by name (delimited by "-- name: <id>") at runtime.
--
-- Object names are unqualified: the connection's database/schema
-- (HARTFORD.CLAIMS) comes from the JDBC URL. See docs/MIGRATION.md section 5
-- for the Oracle -> Snowflake rewrites applied here.
-- ============================================================================

-- name: agent_org_chart
-- CONNECT BY / LEVEL / SYS_CONNECT_BY_PATH -> recursive CTE. ORDER SIBLINGS BY
-- is emulated with a sort key built from each agent's rank among its siblings.
WITH RECURSIVE ranked AS (
    SELECT agent_id,
           manager_id,
           agent_name,
           ROW_NUMBER() OVER (PARTITION BY manager_id ORDER BY agent_name) AS sibling_rank
      FROM agent
),
org (agent_id, manager_id, agent_name, depth, path, sort_key) AS (
    SELECT agent_id,
           manager_id,
           agent_name,
           1::NUMBER(10,0),
           (' > ' || agent_name)::VARCHAR,
           LPAD(sibling_rank::VARCHAR, 6, '0')::VARCHAR
      FROM ranked
     WHERE manager_id IS NULL
    UNION ALL
    SELECT r.agent_id,
           r.manager_id,
           r.agent_name,
           o.depth + 1,
           o.path || ' > ' || r.agent_name,
           o.sort_key || '.' || LPAD(r.sibling_rank::VARCHAR, 6, '0')
      FROM ranked r
      JOIN org o
        ON r.manager_id = o.agent_id
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
SELECT TO_VARCHAR(p.effective_date, 'YYYY-MM')                  AS ym,
       p.product_code,
       CASE WHEN p.status = 'ACTIVE' THEN 'Y' ELSE 'N' END      AS is_active,
       COUNT(*)                                                 AS policy_count,
       SUM(COALESCE(p.annual_premium, 0))                       AS gross_premium
  FROM policy p
 WHERE p.effective_date >= DATEADD('month', -24, CURRENT_TIMESTAMP())
 GROUP BY ym, p.product_code, is_active
 ORDER BY ym;

-- name: stale_open_claims
-- ROWNUM -> ORDER BY ... LIMIT, SYSDATE arithmetic -> DATEDIFF / DATEADD.
SELECT cl.claim_id,
       cl.claim_number,
       cl.policy_id,
       cl.status,
       DATEDIFF('day', cl.reported_date, CURRENT_TIMESTAMP()) AS days_open,
       cl.reserve_amount
  FROM claim cl
 WHERE cl.status IN ('OPEN', 'INVESTIGATING')
   AND cl.reported_date < DATEADD('day', -30, CURRENT_TIMESTAMP())
 ORDER BY cl.reported_date ASC
 LIMIT 100;

-- name: customer_upsert
-- MERGE ... USING (SELECT ... FROM dual) -> USING (SELECT ...); :1..:4 -> ?.
-- updated_ts is set here because Snowflake has no row-level triggers.
MERGE INTO customer tgt
USING (SELECT ? AS customer_id, ? AS first_name, ? AS last_name, ? AS email) src
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
-- NVL2 -> IFF. Snowflake REGEXP_LIKE matches the whole string (implicitly
-- anchored), so Oracle's '^860-' prefix match becomes '860-.*'.
SELECT c.customer_id,
       c.first_name || ' ' || c.last_name AS full_name,
       c.risk_score,
       IFF(c.email IS NOT NULL, 'HAS_EMAIL', 'NO_EMAIL') AS email_flag,
       RANK() OVER (ORDER BY c.risk_score DESC) AS risk_rank
  FROM customer c
 WHERE c.risk_score > 0.6
   AND REGEXP_LIKE(c.phone, '860-.*')
 ORDER BY risk_rank;
