--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Minimal seed data, translated from db/oracle/04_seed_data.sql.
--   TO_DATE(...)          -> TO_TIMESTAMP_NTZ(...)
--   trigger-assigned PKs  -> column DEFAULT seq.NEXTVAL (omit the column)
--   PL/SQL anonymous block -> CALL open_claim / CALL post_payment
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

-- Agents (org chart: 20 manages 21/22)
INSERT INTO agent (agent_id, agent_name, manager_id, region_code, hire_date) VALUES
  (20, 'Regina Cole', NULL, 'NE', TO_TIMESTAMP_NTZ('2011-03-01', 'YYYY-MM-DD')),
  (21, 'Marcus Webb', 20,   'NE', TO_TIMESTAMP_NTZ('2015-06-15', 'YYYY-MM-DD')),
  (22, 'Priya Nair',  20,   'NE', TO_TIMESTAMP_NTZ('2018-09-10', 'YYYY-MM-DD'));

-- Customers (customer_id defaults from seq_customer_id: 100000, 100001, 100002)
INSERT INTO customer (first_name, last_name, ssn, date_of_birth, email, phone, risk_score, lifetime_premium) VALUES
  ('Alice',  'Johnson', '111-22-3333', TO_TIMESTAMP_NTZ('1980-04-12', 'YYYY-MM-DD'), 'alice.j@example.com', '860-555-0101', 0.42, 12400.00),
  ('Robert', 'Smith',   '222-33-4444', TO_TIMESTAMP_NTZ('1975-11-30', 'YYYY-MM-DD'), 'rsmith@example.com',  '860-555-0102', 0.78, 8800.00),
  ('Maria',  'Garcia',  '333-44-5555', TO_TIMESTAMP_NTZ('1990-07-08', 'YYYY-MM-DD'), 'mgarcia@example.com', '860-555-0103', 0.31, 4200.00);

-- Policies (policy_id defaults from seq_policy_id: 500000..500003)
INSERT INTO policy (policy_number, customer_id, agent_id, product_code, status, effective_date, expiration_date, annual_premium, coverage_limit, deductible) VALUES
  ('POL-AUTO-0001', 100000, 21, 'AUTO', 'ACTIVE', TO_TIMESTAMP_NTZ('2024-01-01', 'YYYY-MM-DD'), TO_TIMESTAMP_NTZ('2025-12-31', 'YYYY-MM-DD'), 1450.00, 100000,  500),
  ('POL-HOME-0002', 100000, 21, 'HOME', 'ACTIVE', TO_TIMESTAMP_NTZ('2024-03-15', 'YYYY-MM-DD'), TO_TIMESTAMP_NTZ('2026-03-14', 'YYYY-MM-DD'), 2100.00, 450000, 1000),
  ('POL-AUTO-0003', 100001, 22, 'AUTO', 'ACTIVE', TO_TIMESTAMP_NTZ('2023-09-01', 'YYYY-MM-DD'), TO_TIMESTAMP_NTZ('2025-08-31', 'YYYY-MM-DD'), 1980.00, 100000,  750),
  ('POL-WC-0004',   100002, 22, 'WC',   'ACTIVE', TO_TIMESTAMP_NTZ('2024-06-01', 'YYYY-MM-DD'), TO_TIMESTAMP_NTZ('2025-05-31', 'YYYY-MM-DD'), 9500.00, 1000000,   0);

-- Open a few claims and post payments via the procedures.
EXECUTE IMMEDIATE $$
DECLARE
  v_claim1 NUMBER;
  v_claim2 NUMBER;
BEGIN
  CALL open_claim(500000, TO_TIMESTAMP_NTZ('2024-08-10', 'YYYY-MM-DD'), 'COLLISION', 'Rear-end collision on I-84') INTO :v_claim1;
  CALL open_claim(500003, TO_TIMESTAMP_NTZ('2024-10-02', 'YYYY-MM-DD'), 'INJURY',    'Slip and fall, warehouse floor') INTO :v_claim2;

  CALL post_payment(:v_claim1, 1800.00, 'CHECK', 'CHK-88231');
  CALL post_payment(:v_claim2, 3200.00, 'ACH',   NULL);
  RETURN 'seeded claims ' || v_claim1 || ', ' || v_claim2;
END;
$$;
