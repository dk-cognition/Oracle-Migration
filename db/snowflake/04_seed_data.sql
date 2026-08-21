--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake seed data, migrated from db/oracle/04_seed_data.sql.
--
-- No DUAL, no sequence-driven triggers: customer_id / policy_id / claim_id come
-- from the column DEFAULTs in 01_schema.sql, and SYSDATE becomes
-- CURRENT_TIMESTAMP(). TO_DATE literals are kept (supported in Snowflake) but
-- land in TIMESTAMP_NTZ columns.
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

-- Agents (org chart: 20 manages 21/22)
INSERT INTO hartford.claims.agent (agent_id, agent_name, manager_id, region_code, hire_date)
VALUES (20, 'Regina Cole', NULL, 'NE', TO_DATE('2011-03-01', 'YYYY-MM-DD')),
       (21, 'Marcus Webb', 20,   'NE', TO_DATE('2015-06-15', 'YYYY-MM-DD')),
       (22, 'Priya Nair',  20,   'NE', TO_DATE('2018-09-10', 'YYYY-MM-DD'));

-- Customers (customer_id / created_ts / updated_ts come from column DEFAULTs)
INSERT INTO hartford.claims.customer
  (first_name, last_name, ssn, date_of_birth, email, phone, risk_score, lifetime_premium)
VALUES ('Alice',  'Johnson', '111-22-3333', TO_DATE('1980-04-12', 'YYYY-MM-DD'), 'alice.j@example.com', '860-555-0101', 0.42, 12400.00),
       ('Robert', 'Smith',   '222-33-4444', TO_DATE('1975-11-30', 'YYYY-MM-DD'), 'rsmith@example.com',  '860-555-0102', 0.78, 8800.00),
       ('Maria',  'Garcia',  '333-44-5555', TO_DATE('1990-07-08', 'YYYY-MM-DD'), 'mgarcia@example.com', '860-555-0103', 0.31, 4200.00);

-- Policies (policy_id from the seq_policy_id DEFAULT)
INSERT INTO hartford.claims.policy
  (policy_number, customer_id, agent_id, product_code, status,
   effective_date, expiration_date, annual_premium, coverage_limit, deductible)
VALUES ('POL-AUTO-0001', 100000, 21, 'AUTO', 'ACTIVE', TO_DATE('2024-01-01', 'YYYY-MM-DD'), TO_DATE('2025-12-31', 'YYYY-MM-DD'), 1450.00, 100000, 500),
       ('POL-HOME-0002', 100000, 21, 'HOME', 'ACTIVE', TO_DATE('2024-03-15', 'YYYY-MM-DD'), TO_DATE('2026-03-14', 'YYYY-MM-DD'), 2100.00, 450000, 1000),
       ('POL-AUTO-0003', 100001, 22, 'AUTO', 'ACTIVE', TO_DATE('2023-09-01', 'YYYY-MM-DD'), TO_DATE('2025-08-31', 'YYYY-MM-DD'), 1980.00, 100000, 750),
       ('POL-WC-0004',   100002, 22, 'WC',   'ACTIVE', TO_DATE('2024-06-01', 'YYYY-MM-DD'), TO_DATE('2025-05-31', 'YYYY-MM-DD'), 9500.00, 1000000, 0);

-- Open a couple of claims and pay them through the migrated procedures.
-- Snowflake Scripting replaces the anonymous PL/SQL block; procedure results are
-- read with RESULTSET / :sqlrowcount-free CALL ... INTO semantics.
DECLARE
  v_claim1 NUMBER;
  v_claim2 NUMBER;
BEGIN
  v_claim1 := (CALL hartford.claims.sp_open_claim(500000, TO_TIMESTAMP_NTZ('2024-08-10'), 'COLLISION', 'Rear-end collision on I-84'));
  v_claim2 := (CALL hartford.claims.sp_open_claim(500003, TO_TIMESTAMP_NTZ('2024-10-02'), 'INJURY',    'Slip and fall, warehouse floor'));

  CALL hartford.claims.sp_post_payment(:v_claim1, 1800.00, 'CHECK', 'CHK-88231');
  CALL hartford.claims.sp_post_payment(:v_claim2, 3200.00, 'ACH',   NULL);

  RETURN 'seeded claims ' || :v_claim1 || ', ' || :v_claim2;
END;
