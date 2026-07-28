--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake seed data, migrated from db/oracle/04_seed_data.sql.
--
-- Migration notes (see docs/MIGRATION.md):
--   * TO_DATE(...) into Oracle DATE columns -> TO_TIMESTAMP_NTZ(...), keeping the
--     time component the target TIMESTAMP_NTZ columns carry.
--   * customer_id / policy_id are omitted: the Oracle BEFORE INSERT triggers are
--     replaced by sequence / AUTOINCREMENT column defaults in 01_schema.sql.
--   * The PL/SQL anonymous block becomes a Snowflake Scripting block that CALLs
--     the migrated procedures; there is no explicit COMMIT (each statement in a
--     block autocommits unless a transaction is opened).
--------------------------------------------------------------------------------

USE DATABASE hartford;
USE SCHEMA hartford.claims;

-- Agents (org chart: 20 manages 21/22)
INSERT INTO hartford.claims.agent (agent_id, agent_name, manager_id, region_code, hire_date) VALUES
  (20, 'Regina Cole', NULL, 'NE', TO_TIMESTAMP_NTZ('2011-03-01', 'YYYY-MM-DD')),
  (21, 'Marcus Webb', 20,   'NE', TO_TIMESTAMP_NTZ('2015-06-15', 'YYYY-MM-DD')),
  (22, 'Priya Nair',  20,   'NE', TO_TIMESTAMP_NTZ('2018-09-10', 'YYYY-MM-DD'));

-- Customers (customer_id defaulted from seq_customer_id, starting at 100000)
INSERT INTO hartford.claims.customer
  (first_name, last_name, ssn, date_of_birth, email, phone, risk_score, lifetime_premium) VALUES
  ('Alice',  'Johnson', '111-22-3333', TO_TIMESTAMP_NTZ('1980-04-12', 'YYYY-MM-DD'), 'alice.j@example.com', '860-555-0101', 0.42, 12400.00),
  ('Robert', 'Smith',   '222-33-4444', TO_TIMESTAMP_NTZ('1975-11-30', 'YYYY-MM-DD'), 'rsmith@example.com',  '860-555-0102', 0.78, 8800.00),
  ('Maria',  'Garcia',  '333-44-5555', TO_TIMESTAMP_NTZ('1990-07-08', 'YYYY-MM-DD'), 'mgarcia@example.com', '860-555-0103', 0.31, 4200.00);

-- Policies (policy_id assigned by the AUTOINCREMENT column, starting at 500000)
INSERT INTO hartford.claims.policy
  (policy_number, customer_id, agent_id, product_code, status, effective_date, expiration_date,
   annual_premium, coverage_limit, deductible) VALUES
  ('POL-AUTO-0001', 100000, 21, 'AUTO', 'ACTIVE', TO_TIMESTAMP_NTZ('2024-01-01', 'YYYY-MM-DD'), TO_TIMESTAMP_NTZ('2025-12-31', 'YYYY-MM-DD'), 1450.00, 100000,  500),
  ('POL-HOME-0002', 100000, 21, 'HOME', 'ACTIVE', TO_TIMESTAMP_NTZ('2024-03-15', 'YYYY-MM-DD'), TO_TIMESTAMP_NTZ('2026-03-14', 'YYYY-MM-DD'), 2100.00, 450000,  1000),
  ('POL-AUTO-0003', 100001, 22, 'AUTO', 'ACTIVE', TO_TIMESTAMP_NTZ('2023-09-01', 'YYYY-MM-DD'), TO_TIMESTAMP_NTZ('2025-08-31', 'YYYY-MM-DD'), 1980.00, 100000,  750),
  ('POL-WC-0004',   100002, 22, 'WC',   'ACTIVE', TO_TIMESTAMP_NTZ('2024-06-01', 'YYYY-MM-DD'), TO_TIMESTAMP_NTZ('2025-05-31', 'YYYY-MM-DD'), 9500.00, 1000000, 0);

-- Open a few claims and pay them through the migrated procedures.
DECLARE
  v_policy1 NUMBER;
  v_policy2 NUMBER;
  v_claim1  NUMBER;
  v_claim2  NUMBER;
BEGIN
  SELECT policy_id INTO :v_policy1
    FROM hartford.claims.policy WHERE policy_number = 'POL-AUTO-0001';
  SELECT policy_id INTO :v_policy2
    FROM hartford.claims.policy WHERE policy_number = 'POL-WC-0004';

  CALL hartford.claims.open_claim(
    :v_policy1, TO_TIMESTAMP_NTZ('2024-08-10', 'YYYY-MM-DD'),
    'COLLISION', 'Rear-end collision on I-84') INTO :v_claim1;

  CALL hartford.claims.open_claim(
    :v_policy2, TO_TIMESTAMP_NTZ('2024-10-02', 'YYYY-MM-DD'),
    'INJURY', 'Slip and fall, warehouse floor') INTO :v_claim2;

  CALL hartford.claims.post_payment(:v_claim1, 1800.00, 'CHECK', 'CHK-88231');
  CALL hartford.claims.post_payment(:v_claim2, 3200.00, 'ACH', NULL);

  RETURN 'seeded';
END;
