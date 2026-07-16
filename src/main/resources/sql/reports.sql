-- ============================================================================
-- Reporting queries used by the Java report/ETL layer.
-- These are loaded by name (delimited by "-- name: <id>") at runtime.
--
-- MIGRATION WARNING: every query below contains at least one Oracle-only
-- construct. See docs/MIGRATION.md for the Snowflake-equivalent rewrites.
-- ============================================================================

-- name: agent_org_chart
-- Oracle hierarchical query (CONNECT BY). Snowflake => recursive CTE.
SELECT LPAD(' ', 2 * (LEVEL - 1)) || agent_name AS org_line,
       agent_id,
       manager_id,
       LEVEL AS depth,
       SYS_CONNECT_BY_PATH(agent_name, ' > ') AS path
  FROM hartford.agent
 START WITH manager_id IS NULL
CONNECT BY PRIOR agent_id = manager_id
 ORDER SIBLINGS BY agent_name;

-- name: monthly_premium
-- TO_CHAR date formatting + DECODE + NVL. Snowflake => TO_VARCHAR / CASE / COALESCE.
SELECT TO_CHAR(p.effective_date, 'YYYY-MM')            AS ym,
       p.product_code,
       DECODE(p.status, 'ACTIVE', 'Y', 'N')            AS is_active,
       COUNT(*)                                        AS policy_count,
       SUM(NVL(p.annual_premium, 0))                   AS gross_premium
  FROM hartford.policy p
 WHERE p.effective_date >= ADD_MONTHS(SYSDATE, -24)
 GROUP BY TO_CHAR(p.effective_date, 'YYYY-MM'), p.product_code,
          DECODE(p.status, 'ACTIVE', 'Y', 'N')
 ORDER BY ym;

-- name: stale_open_claims
-- ROWNUM pagination + SYSDATE arithmetic (days). Snowflake => QUALIFY / DATEDIFF.
SELECT *
  FROM (
    SELECT cl.claim_id,
           cl.claim_number,
           cl.policy_id,
           cl.status,
           ROUND(SYSDATE - cl.reported_date) AS days_open,
           cl.reserve_amount
      FROM hartford.claim cl
     WHERE cl.status IN ('OPEN', 'INVESTIGATING')
       AND cl.reported_date < SYSDATE - 30
     ORDER BY cl.reported_date ASC
  )
 WHERE ROWNUM <= 100;

-- name: customer_upsert
-- Oracle MERGE against DUAL with bind variables. Snowflake supports MERGE but
-- not the ":=" style binds shown here (uses ? or :name via the driver).
MERGE INTO hartford.customer tgt
USING (SELECT :1 AS customer_id, :2 AS first_name, :3 AS last_name, :4 AS email FROM dual) src
   ON (tgt.customer_id = src.customer_id)
 WHEN MATCHED THEN
   UPDATE SET tgt.first_name = src.first_name,
              tgt.last_name  = src.last_name,
              tgt.email      = src.email,
              tgt.updated_ts = SYSDATE
 WHEN NOT MATCHED THEN
   INSERT (customer_id, first_name, last_name, email)
   VALUES (src.customer_id, src.first_name, src.last_name, src.email);

-- name: high_risk_customers
-- Analytic function + NVL2 + regexp. Ports mostly cleanly but NVL2 => IFF/CASE.
-- DATA GOVERNANCE: ReportRunner prints this result set to stdout/logs, which can
-- be read by a broader audience than the database (ops, log pipeline). Do NOT
-- expose raw customer names or the raw underwriting risk_score on this path.
-- We surface only the surrogate customer_id and a coarse risk_band; join back on
-- customer_id inside an access-controlled context when the detail is required.
SELECT c.customer_id,
       CASE
         WHEN c.risk_score >= 0.9 THEN 'VERY_HIGH'
         WHEN c.risk_score >= 0.75 THEN 'HIGH'
         ELSE 'ELEVATED'
       END                                     AS risk_band,
       NVL2(c.email, 'HAS_EMAIL', 'NO_EMAIL') AS email_flag,
       RANK() OVER (ORDER BY c.risk_score DESC) AS risk_rank
  FROM hartford.customer c
 WHERE c.risk_score > 0.6
   AND REGEXP_LIKE(c.phone, '^860-')
 ORDER BY risk_rank;
