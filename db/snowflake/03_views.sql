--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake reporting views, translated from db/oracle/03_views.sql.
--
-- Rewrites applied (see docs/MIGRATION.md):
--   (+) legacy outer join -> LEFT JOIN       ROWNUM -> QUALIFY ROW_NUMBER()
--   DECODE -> CASE                           NVL    -> COALESCE
--   SYSDATE -> CURRENT_TIMESTAMP()           TRUNC(date) -> DATE_TRUNC('DAY', ...)
--   REFRESH FAST ON COMMIT -> dropped (Snowflake MVs are auto-maintained)
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- Active policies with customer + agent info.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_active_policies AS
SELECT p.policy_id,
       p.policy_number,
       c.customer_id,
       c.first_name || ' ' || c.last_name        AS customer_name,
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
       END                                       AS product_desc
  FROM policy p
  JOIN customer c
    ON c.customer_id = p.customer_id
  LEFT JOIN agent a
    ON a.agent_id = p.agent_id
 WHERE p.status = 'ACTIVE'
   AND p.expiration_date > CURRENT_TIMESTAMP();

--------------------------------------------------------------------------------
-- Claim summary per policy.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_claim_summary AS
SELECT p.policy_id,
       p.policy_number,
       COUNT(cl.claim_id)                        AS claim_count,
       COALESCE(SUM(cl.paid_amount), 0)          AS total_paid,
       COALESCE(SUM(cl.reserve_amount), 0)       AS total_reserve,
       ROUND(COALESCE(SUM(cl.paid_amount), 0) / NULLIF(p.annual_premium, 0), 4) AS loss_ratio
  FROM policy p
  LEFT JOIN claim cl
    ON cl.policy_id = p.policy_id
 GROUP BY p.policy_id, p.policy_number, p.annual_premium;

--------------------------------------------------------------------------------
-- Top 10 largest open claims.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_top_open_claims AS
SELECT cl.claim_id,
       cl.claim_number,
       cl.policy_id,
       cl.reserve_amount,
       cl.paid_amount,
       cl.status
  FROM claim cl
 WHERE cl.status IN ('OPEN', 'INVESTIGATING')
QUALIFY ROW_NUMBER() OVER (ORDER BY cl.reserve_amount DESC) <= 10
 ORDER BY cl.reserve_amount DESC;

--------------------------------------------------------------------------------
-- Materialized view: daily paid totals. Single-table aggregate, which Snowflake
-- MVs support; Snowflake maintains it automatically (no refresh clause).
--------------------------------------------------------------------------------
CREATE OR REPLACE MATERIALIZED VIEW mv_daily_paid AS
SELECT DATE_TRUNC('DAY', cp.payment_date) AS pay_day,
       COUNT(*)                           AS payment_count,
       SUM(cp.amount)                     AS total_amount
  FROM claim_payment cp
 GROUP BY DATE_TRUNC('DAY', cp.payment_date);
