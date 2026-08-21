--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake reporting views, migrated from db/oracle/03_views.sql.
--
-- Rewrites applied (docs/MIGRATION.md section 5):
--   (+) outer joins -> ANSI LEFT JOIN
--   ROWNUM <= n     -> QUALIFY ROW_NUMBER() OVER (...) <= n
--   CONNECT BY / SYS_CONNECT_BY_PATH / LEVEL -> WITH RECURSIVE CTE
--   DECODE          -> CASE
--   NVL             -> COALESCE
--   SYSDATE         -> CURRENT_TIMESTAMP()
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- Active policies with customer + agent info.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW hartford.claims.vw_active_policies AS
SELECT p.policy_id,
       p.policy_number,
       c.customer_id,
       c.first_name || ' ' || c.last_name AS customer_name,
       a.agent_name,
       p.product_code,
       p.annual_premium,
       p.effective_date,
       p.expiration_date,
       CASE p.product_code
            WHEN 'AUTO'     THEN 'Automobile'
            WHEN 'HOME'     THEN 'Homeowners'
            WHEN 'UMBRELLA' THEN 'Personal Umbrella'
            WHEN 'WC'       THEN 'Workers Comp'
            ELSE 'Other'
       END AS product_desc
  FROM hartford.claims.policy p
  JOIN hartford.claims.customer c
    ON p.customer_id = c.customer_id
  LEFT JOIN hartford.claims.agent a
    ON p.agent_id = a.agent_id
 WHERE p.status = 'ACTIVE'
   AND p.expiration_date > CURRENT_TIMESTAMP();

--------------------------------------------------------------------------------
-- Claim summary per policy.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW hartford.claims.vw_claim_summary AS
SELECT p.policy_id,
       p.policy_number,
       COUNT(cl.claim_id)                   AS claim_count,
       COALESCE(SUM(cl.paid_amount), 0)     AS total_paid,
       COALESCE(SUM(cl.reserve_amount), 0)  AS total_reserve,
       ROUND(COALESCE(SUM(cl.paid_amount), 0) / NULLIF(p.annual_premium, 0), 4) AS loss_ratio
  FROM hartford.claims.policy p
  LEFT JOIN hartford.claims.claim cl
    ON p.policy_id = cl.policy_id
 GROUP BY p.policy_id, p.policy_number, p.annual_premium;

--------------------------------------------------------------------------------
-- Top 10 largest open claims (ROWNUM -> QUALIFY).
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW hartford.claims.vw_top_open_claims AS
SELECT cl.claim_id,
       cl.claim_number,
       cl.policy_id,
       cl.reserve_amount,
       cl.paid_amount,
       cl.status
  FROM hartford.claims.claim cl
 WHERE cl.status IN ('OPEN', 'INVESTIGATING')
QUALIFY ROW_NUMBER() OVER (ORDER BY cl.reserve_amount DESC) <= 10;

--------------------------------------------------------------------------------
-- Agent org chart: CONNECT BY / SYS_CONNECT_BY_PATH / LEVEL -> WITH RECURSIVE.
-- Same shape as the agent_org_chart query in src/main/resources/sql/reports.sql.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW hartford.claims.vw_agent_org_chart AS
WITH RECURSIVE org AS (
    SELECT a.agent_id,
           a.manager_id,
           a.agent_name,
           1                             AS depth,
           a.agent_name                  AS path
      FROM hartford.claims.agent a
     WHERE a.manager_id IS NULL
    UNION ALL
    SELECT a.agent_id,
           a.manager_id,
           a.agent_name,
           o.depth + 1                   AS depth,
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
  FROM org;

--------------------------------------------------------------------------------
-- Daily paid totals. Snowflake materialized views auto-maintain, so Oracle's
-- BUILD IMMEDIATE / REFRESH FAST ON COMMIT clauses are dropped (section 6).
-- Single-table aggregate, so it is a legal Snowflake MV.
--------------------------------------------------------------------------------
CREATE OR REPLACE MATERIALIZED VIEW hartford.claims.mv_daily_paid AS
SELECT DATE_TRUNC('DAY', cp.payment_date) AS pay_day,
       COUNT(*)                           AS payment_count,
       SUM(cp.amount)                     AS total_amount
  FROM hartford.claims.claim_payment cp
 GROUP BY DATE_TRUNC('DAY', cp.payment_date);
