--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Reporting views + one materialized view.
--
-- NOTE (migration): these views use legacy Oracle join syntax (+), DECODE,
-- NVL, and ROWNUM. Snowflake supports standard views but not (+) outer joins,
-- and ROWNUM must be replaced with QUALIFY / ROW_NUMBER(). Materialized views
-- exist in Snowflake but with heavy restrictions (no joins). See docs/MIGRATION.md.
--------------------------------------------------------------------------------

ALTER SESSION SET CURRENT_SCHEMA = HARTFORD;

--------------------------------------------------------------------------------
-- Active policies with customer + agent info.
-- Uses Oracle (+) left-outer-join syntax on the agent join.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW hartford.vw_active_policies AS
SELECT p.policy_id,
       p.policy_number,
       c.customer_id,
       c.first_name || ' ' || c.last_name        AS customer_name,
       a.agent_name,
       p.product_code,
       p.annual_premium,
       p.effective_date,
       p.expiration_date,
       DECODE(p.product_code,
              'AUTO',    'Automobile',
              'HOME',    'Homeowners',
              'UMBRELLA','Personal Umbrella',
              'WC',      'Workers Comp',
              'Other')                            AS product_desc
  FROM hartford.policy p,
       hartford.customer c,
       hartford.agent a
 WHERE p.customer_id = c.customer_id
   AND p.agent_id    = a.agent_id (+)          -- legacy outer join
   AND p.status      = 'ACTIVE'
   AND p.expiration_date > SYSDATE;

--------------------------------------------------------------------------------
-- Claim summary per policy.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW hartford.vw_claim_summary AS
SELECT p.policy_id,
       p.policy_number,
       COUNT(cl.claim_id)                        AS claim_count,
       NVL(SUM(cl.paid_amount), 0)               AS total_paid,
       NVL(SUM(cl.reserve_amount), 0)            AS total_reserve,
       ROUND(NVL(SUM(cl.paid_amount),0) / NULLIF(p.annual_premium,0), 4) AS loss_ratio
  FROM hartford.policy p,
       hartford.claim cl
 WHERE p.policy_id = cl.policy_id (+)
 GROUP BY p.policy_id, p.policy_number, p.annual_premium;

--------------------------------------------------------------------------------
-- Top 10 largest open claims (ROWNUM pagination - Oracle-specific).
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW hartford.vw_top_open_claims AS
SELECT *
  FROM (
    SELECT cl.claim_id,
           cl.claim_number,
           cl.policy_id,
           cl.reserve_amount,
           cl.paid_amount,
           cl.status
      FROM hartford.claim cl
     WHERE cl.status IN ('OPEN','INVESTIGATING')
     ORDER BY cl.reserve_amount DESC
  )
 WHERE ROWNUM <= 10;

--------------------------------------------------------------------------------
-- Materialized view: daily paid totals (Oracle fast-refresh).
--------------------------------------------------------------------------------
CREATE MATERIALIZED VIEW hartford.mv_daily_paid
  BUILD IMMEDIATE
  REFRESH FAST ON COMMIT
AS
SELECT TRUNC(cp.payment_date) AS pay_day,
       COUNT(*)               AS payment_count,
       SUM(cp.amount)         AS total_amount
  FROM hartford.claim_payment cp
 GROUP BY TRUNC(cp.payment_date);
