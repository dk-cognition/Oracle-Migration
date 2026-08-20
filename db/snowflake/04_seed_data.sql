--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake seed data, migrated from db/oracle/04_seed_data.sql.
--
-- Migration notes (see docs/MIGRATION.md):
--   * ALTER SESSION SET CURRENT_SCHEMA -> USE SCHEMA
--   * TO_DATE('...','YYYY-MM-DD') literals -> ISO TIMESTAMP_NTZ literals
--     (columns are TIMESTAMP_NTZ; Snowflake casts 'YYYY-MM-DD' strings directly)
--   * Trigger-assigned ids -> AUTOINCREMENT column defaults (omit the column)
--   * PL/SQL anonymous block -> CALL open_claim(...) / CALL post_payment(...)
--   * No FROM dual anywhere; no explicit COMMIT (autocommit per statement)
--------------------------------------------------------------------------------

USE SCHEMA hartford;

-- Agents (org chart: 20 manages 21/22)
INSERT INTO agent (agent_id, agent_name, manager_id, region_code, hire_date)
VALUES (20, 'Regina Cole', NULL, 'NE', '2011-03-01'),
       (21, 'Marcus Webb', 20,   'NE', '2015-06-15'),
       (22, 'Priya Nair',  20,   'NE', '2018-09-10');

-- Customers (AUTOINCREMENT assigns customer_id starting at 100000)
INSERT INTO customer (first_name, last_name, ssn, date_of_birth, email, phone, risk_score, lifetime_premium)
VALUES ('Alice',  'Johnson', '111-22-3333', '1980-04-12', 'alice.j@example.com', '860-555-0101', 0.42, 12400.00),
       ('Robert', 'Smith',   '222-33-4444', '1975-11-30', 'rsmith@example.com',  '860-555-0102', 0.78, 8800.00),
       ('Maria',  'Garcia',  '333-44-5555', '1990-07-08', 'mgarcia@example.com', '860-555-0103', 0.31, 4200.00);

-- Policies (AUTOINCREMENT assigns policy_id starting at 500000)
INSERT INTO policy (policy_number, customer_id, agent_id, product_code, status, effective_date, expiration_date, annual_premium, coverage_limit, deductible)
VALUES ('POL-AUTO-0001', 100000, 21, 'AUTO', 'ACTIVE', '2024-01-01', '2025-12-31', 1450.00, 100000, 500),
       ('POL-HOME-0002', 100000, 21, 'HOME', 'ACTIVE', '2024-03-15', '2026-03-14', 2100.00, 450000, 1000),
       ('POL-AUTO-0003', 100001, 22, 'AUTO', 'ACTIVE', '2023-09-01', '2025-08-31', 1980.00, 100000, 750),
       ('POL-WC-0004',   100002, 22, 'WC',   'ACTIVE', '2024-06-01', '2025-05-31', 9500.00, 1000000, 0);

-- Open a few claims via the migrated procedures (replaces the PL/SQL anonymous
-- block). Snowflake Scripting: CALL ... INTO captures each returned claim_id.
EXECUTE IMMEDIATE
$$
DECLARE
  v_claim1 NUMBER;
  v_claim2 NUMBER;
BEGIN
  CALL open_claim(500000, '2024-08-10'::TIMESTAMP_NTZ, 'COLLISION', 'Rear-end collision on I-84') INTO :v_claim1;
  CALL open_claim(500003, '2024-10-02'::TIMESTAMP_NTZ, 'INJURY',    'Slip and fall, warehouse floor') INTO :v_claim2;

  CALL post_payment(:v_claim1, 1800.00, 'CHECK', 'CHK-88231');
  CALL post_payment(:v_claim2, 3200.00, 'ACH',   NULL);
END;
$$;
