--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Minimal seed data, migrated from db/oracle/04_seed_data.sql.
-- TO_DATE literals -> TIMESTAMP_NTZ literals; sequence/trigger-assigned ids ->
-- column defaults; PL/SQL anonymous block -> Snowflake Scripting block.
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

-- Agents (org chart: 20 manages 21/22)
INSERT INTO hartford.claims.agent (agent_id, agent_name, manager_id, region_code, hire_date) VALUES
  (20, 'Regina Cole', NULL, 'NE', '2011-03-01'::TIMESTAMP_NTZ),
  (21, 'Marcus Webb', 20,   'NE', '2015-06-15'::TIMESTAMP_NTZ),
  (22, 'Priya Nair',  20,   'NE', '2018-09-10'::TIMESTAMP_NTZ);

-- Customers (customer_id from DEFAULT seq_customer_id.NEXTVAL: 100000..100002)
INSERT INTO hartford.claims.customer (first_name, last_name, ssn, date_of_birth, email, phone, risk_score, lifetime_premium) VALUES
  ('Alice',  'Johnson', '111-22-3333', '1980-04-12'::TIMESTAMP_NTZ, 'alice.j@example.com', '860-555-0101', 0.42, 12400.00),
  ('Robert', 'Smith',   '222-33-4444', '1975-11-30'::TIMESTAMP_NTZ, 'rsmith@example.com',  '860-555-0102', 0.78,  8800.00),
  ('Maria',  'Garcia',  '333-44-5555', '1990-07-08'::TIMESTAMP_NTZ, 'mgarcia@example.com', '860-555-0103', 0.31,  4200.00);

-- Policies (policy_id from AUTOINCREMENT: 500000..500003)
INSERT INTO hartford.claims.policy (policy_number, customer_id, agent_id, product_code, status, effective_date, expiration_date, annual_premium, coverage_limit, deductible) VALUES
  ('POL-AUTO-0001', 100000, 21, 'AUTO', 'ACTIVE', '2024-01-01'::TIMESTAMP_NTZ, '2025-12-31'::TIMESTAMP_NTZ, 1450.00,  100000,  500),
  ('POL-HOME-0002', 100000, 21, 'HOME', 'ACTIVE', '2024-03-15'::TIMESTAMP_NTZ, '2026-03-14'::TIMESTAMP_NTZ, 2100.00,  450000, 1000),
  ('POL-AUTO-0003', 100001, 22, 'AUTO', 'ACTIVE', '2023-09-01'::TIMESTAMP_NTZ, '2025-08-31'::TIMESTAMP_NTZ, 1980.00,  100000,  750),
  ('POL-WC-0004',   100002, 22, 'WC',   'ACTIVE', '2024-06-01'::TIMESTAMP_NTZ, '2025-05-31'::TIMESTAMP_NTZ, 9500.00, 1000000,    0);

-- Open a few claims via the procedures.
EXECUTE IMMEDIATE $$
DECLARE
  v_claim1 NUMBER;
  v_claim2 NUMBER;
BEGIN
  CALL hartford.claims.open_claim(500000, '2024-08-10'::TIMESTAMP_NTZ, 'COLLISION', 'Rear-end collision on I-84') INTO :v_claim1;
  CALL hartford.claims.open_claim(500003, '2024-10-02'::TIMESTAMP_NTZ, 'INJURY',    'Slip and fall, warehouse floor') INTO :v_claim2;

  CALL hartford.claims.post_payment(:v_claim1, 1800.00, 'CHECK', 'CHK-88231');
  CALL hartford.claims.post_payment(:v_claim2, 3200.00, 'ACH',   NULL);
END;
$$;
