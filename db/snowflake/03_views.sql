--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Reporting views + materialized view, migrated from db/oracle/03_views.sql.
--
-- Rewrites applied (docs/MIGRATION.md section 5):
--   (+) outer joins     -> ANSI LEFT JOIN
--   ROWNUM <= n         -> ORDER BY ... LIMIT n
--   CONNECT BY          -> WITH RECURSIVE (vw_agent_org_chart)
--   DECODE / NVL        -> CASE / COALESCE
--   SYSDATE             -> CURRENT_TIMESTAMP()
--   a || ' ' || b       -> COALESCE-wrapped (Oracle treats NULL as '' in ||,
--                          Snowflake returns NULL)
--   MV REFRESH FAST ON COMMIT -> dropped (Snowflake MVs auto-maintain)
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- Active policies with customer + agent info.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW hartford.claims.vw_active_policies AS
SELECT p.policy_id,
       p.policy_number,
       c.customer_id,
       COALESCE(c.first_name, '') || ' ' || COALESCE(c.last_name, '') AS customer_name,
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
       END                                                             AS product_desc
  FROM hartford.claims.policy p
  JOIN hartford.claims.customer c
    ON c.customer_id = p.customer_id
  LEFT JOIN hartford.claims.agent a
    ON a.agent_id = p.agent_id
 WHERE p.status = 'ACTIVE'
   AND p.expiration_date > CURRENT_TIMESTAMP()::TIMESTAMP_NTZ;

--------------------------------------------------------------------------------
-- Claim summary per policy.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW hartford.claims.vw_claim_summary AS
SELECT p.policy_id,
       p.policy_number,
       COUNT(cl.claim_id)                                                       AS claim_count,
       COALESCE(SUM(cl.paid_amount), 0)                                         AS total_paid,
       COALESCE(SUM(cl.reserve_amount), 0)                                      AS total_reserve,
       ROUND(COALESCE(SUM(cl.paid_amount), 0) / NULLIF(p.annual_premium, 0), 4) AS loss_ratio
  FROM hartford.claims.policy p
  LEFT JOIN hartford.claims.claim cl
    ON cl.policy_id = p.policy_id
 GROUP BY p.policy_id, p.policy_number, p.annual_premium;

--------------------------------------------------------------------------------
-- Top 10 largest open claims.
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
 ORDER BY cl.reserve_amount DESC
 LIMIT 10;

--------------------------------------------------------------------------------
-- Agent org chart (replaces the CONNECT BY hierarchy in reports.sql).
-- LEVEL -> depth counter; SYS_CONNECT_BY_PATH -> path built per recursion;
-- ORDER SIBLINGS BY agent_name -> order by sort_key (names joined with CHR(1),
-- which sorts below any printable character, so children follow their parent).
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW hartford.claims.vw_agent_org_chart AS
WITH RECURSIVE org (agent_id, manager_id, agent_name, depth, path, sort_key) AS (
  SELECT agent_id,
         manager_id,
         agent_name,
         1,
         CAST(' > ' || agent_name AS VARCHAR),
         CAST(agent_name AS VARCHAR)
    FROM hartford.claims.agent
   WHERE manager_id IS NULL
  UNION ALL
  SELECT a.agent_id,
         a.manager_id,
         a.agent_name,
         o.depth + 1,
         o.path || ' > ' || a.agent_name,
         o.sort_key || CHR(1) || a.agent_name
    FROM hartford.claims.agent a
    JOIN org o
      ON a.manager_id = o.agent_id
)
SELECT REPEAT(' ', 2 * (depth - 1)) || agent_name AS org_line,
       agent_id,
       manager_id,
       depth,
       path,
       sort_key
  FROM org;

--------------------------------------------------------------------------------
-- Materialized view: daily paid totals. Requires Snowflake Enterprise Edition;
-- Snowflake maintains it automatically (no REFRESH clause).
--------------------------------------------------------------------------------
CREATE OR REPLACE MATERIALIZED VIEW hartford.claims.mv_daily_paid AS
SELECT DATE_TRUNC('DAY', cp.payment_date) AS pay_day,
       COUNT(*)                           AS payment_count,
       SUM(cp.amount)                     AS total_amount
  FROM hartford.claims.claim_payment cp
 GROUP BY DATE_TRUNC('DAY', cp.payment_date);
