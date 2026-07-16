-- ============================================================================
-- Reporting queries used by the Java report/ETL layer.
-- These are loaded by name (delimited by "-- name: <id>") at runtime.
--
-- MIGRATED to Snowflake. Every query below was rewritten from its Oracle form
-- (CONNECT BY, ROWNUM, (+), DECODE, NVL/NVL2, SYSDATE, ADD_MONTHS, TO_CHAR,
-- DUAL, ...). See docs/MIGRATION.md sections 5 & 7 for the mapping.
-- ============================================================================

-- name: agent_org_chart
-- Oracle CONNECT BY / START WITH / SYS_CONNECT_BY_PATH / LEVEL -> WITH RECURSIVE.
-- depth is the LEVEL counter; path is built like SYS_CONNECT_BY_PATH(agent_name,' > ');
-- ORDER SIBLINGS BY agent_name is approximated by ORDER BY path.
WITH RECURSIVE org (agent_id, manager_id, agent_name, depth, path, org_line) AS (
  SELECT agent_id,
         manager_id,
         agent_name,
         1                                        AS depth,
         ' > ' || agent_name                      AS path,
         agent_name                               AS org_line
    FROM hartford.agent
   WHERE manager_id IS NULL
  UNION ALL
  SELECT a.agent_id,
         a.manager_id,
         a.agent_name,
         o.depth + 1,
         o.path || ' > ' || a.agent_name,
         LPAD(' ', 2 * o.depth, ' ') || a.agent_name
    FROM hartford.agent a
    JOIN org o ON a.manager_id = o.agent_id
)
SELECT org_line,
       agent_id,
       manager_id,
       depth,
       path
  FROM org
 ORDER BY path;

-- name: monthly_premium
-- TO_CHAR -> TO_VARCHAR; ADD_MONTHS -> DATEADD; DECODE -> CASE; NVL -> COALESCE.
SELECT TO_VARCHAR(p.effective_date, 'YYYY-MM')            AS ym,
       p.product_code,
       CASE WHEN p.status = 'ACTIVE' THEN 'Y' ELSE 'N' END AS is_active,
       COUNT(*)                                           AS policy_count,
       SUM(COALESCE(p.annual_premium, 0))                 AS gross_premium
  FROM hartford.policy p
 WHERE p.effective_date >= DATEADD('month', -24, CURRENT_TIMESTAMP())
 GROUP BY TO_VARCHAR(p.effective_date, 'YYYY-MM'), p.product_code,
          CASE WHEN p.status = 'ACTIVE' THEN 'Y' ELSE 'N' END
 ORDER BY ym;

-- name: stale_open_claims
-- ROWNUM -> QUALIFY ROW_NUMBER(); SYSDATE - reported_date -> DATEDIFF; SYSDATE - 30 -> DATEADD.
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
-- MERGE kept; USING (SELECT ... FROM dual) -> USING (SELECT ...) src (no DUAL);
-- positional binds :1..:4 -> JDBC ? placeholders; SYSDATE -> CURRENT_TIMESTAMP().
MERGE INTO hartford.customer tgt
USING (SELECT ? AS customer_id, ? AS first_name, ? AS last_name, ? AS email) src
   ON (tgt.customer_id = src.customer_id)
 WHEN MATCHED THEN
   UPDATE SET tgt.first_name = src.first_name,
              tgt.last_name  = src.last_name,
              tgt.email      = src.email,
              tgt.updated_ts = CURRENT_TIMESTAMP()
 WHEN NOT MATCHED THEN
   INSERT (customer_id, first_name, last_name, email)
   VALUES (src.customer_id, src.first_name, src.last_name, src.email);

-- name: high_risk_customers
-- NVL2 -> IFF(... IS NOT NULL, ...); REGEXP_LIKE is implicitly whole-string
-- anchored in Snowflake, so Oracle '^860-' becomes '860-.*'.
SELECT c.customer_id,
       c.first_name || ' ' || c.last_name AS full_name,
       c.risk_score,
       IFF(c.email IS NOT NULL, 'HAS_EMAIL', 'NO_EMAIL') AS email_flag,
       RANK() OVER (ORDER BY c.risk_score DESC) AS risk_rank
  FROM hartford.customer c
 WHERE c.risk_score > 0.6
   AND REGEXP_LIKE(c.phone, '860-.*')
 ORDER BY risk_rank;
