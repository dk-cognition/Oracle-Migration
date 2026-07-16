--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Minimal seed data for the demo. Migrated from db/oracle/04_seed_data.sql.
--
--   * ALTER SESSION SET CURRENT_SCHEMA -> USE SCHEMA.
--   * No DUAL / sequences in the INSERTs: customer_id and policy_id come from
--     AUTOINCREMENT columns; claim_id comes from seq_claim_id (start 900000).
--   * The PL/SQL anonymous block that called claims_pkg -> CALL statements.
--   * TO_DATE literals auto-cast to TIMESTAMP_NTZ.
--------------------------------------------------------------------------------

USE SCHEMA hartford.hartford;

-- Agents (org chart: 20 manages 21/22)
INSERT INTO hartford.agent (agent_id, agent_name, manager_id, region_code, hire_date)
VALUES (20, 'Regina Cole',   NULL, 'NE', TO_DATE('2011-03-01','YYYY-MM-DD'));
INSERT INTO hartford.agent (agent_id, agent_name, manager_id, region_code, hire_date)
VALUES (21, 'Marcus Webb',   20,   'NE', TO_DATE('2015-06-15','YYYY-MM-DD'));
INSERT INTO hartford.agent (agent_id, agent_name, manager_id, region_code, hire_date)
VALUES (22, 'Priya Nair',    20,   'NE', TO_DATE('2018-09-10','YYYY-MM-DD'));

-- Customers (AUTOINCREMENT assigns customer_id from 100000)
INSERT INTO hartford.customer (first_name, last_name, ssn, date_of_birth, email, phone, risk_score, lifetime_premium)
VALUES ('Alice',  'Johnson', '111-22-3333', TO_DATE('1980-04-12','YYYY-MM-DD'), 'alice.j@example.com',  '860-555-0101', 0.42, 12400.00);
INSERT INTO hartford.customer (first_name, last_name, ssn, date_of_birth, email, phone, risk_score, lifetime_premium)
VALUES ('Robert', 'Smith',   '222-33-4444', TO_DATE('1975-11-30','YYYY-MM-DD'), 'rsmith@example.com',   '860-555-0102', 0.78, 8800.00);
INSERT INTO hartford.customer (first_name, last_name, ssn, date_of_birth, email, phone, risk_score, lifetime_premium)
VALUES ('Maria',  'Garcia',  '333-44-5555', TO_DATE('1990-07-08','YYYY-MM-DD'), 'mgarcia@example.com',  '860-555-0103', 0.31, 4200.00);

-- Policies (AUTOINCREMENT assigns policy_id from 500000 -> 500000..500003)
INSERT INTO hartford.policy (policy_number, customer_id, agent_id, product_code, status, effective_date, expiration_date, annual_premium, coverage_limit, deductible)
VALUES ('POL-AUTO-0001', 100000, 21, 'AUTO', 'ACTIVE', TO_DATE('2024-01-01','YYYY-MM-DD'), TO_DATE('2025-12-31','YYYY-MM-DD'), 1450.00, 100000, 500);
INSERT INTO hartford.policy (policy_number, customer_id, agent_id, product_code, status, effective_date, expiration_date, annual_premium, coverage_limit, deductible)
VALUES ('POL-HOME-0002', 100000, 21, 'HOME', 'ACTIVE', TO_DATE('2024-03-15','YYYY-MM-DD'), TO_DATE('2026-03-14','YYYY-MM-DD'), 2100.00, 450000, 1000);
INSERT INTO hartford.policy (policy_number, customer_id, agent_id, product_code, status, effective_date, expiration_date, annual_premium, coverage_limit, deductible)
VALUES ('POL-AUTO-0003', 100001, 22, 'AUTO', 'ACTIVE', TO_DATE('2023-09-01','YYYY-MM-DD'), TO_DATE('2025-08-31','YYYY-MM-DD'), 1980.00, 100000, 750);
INSERT INTO hartford.policy (policy_number, customer_id, agent_id, product_code, status, effective_date, expiration_date, annual_premium, coverage_limit, deductible)
VALUES ('POL-WC-0004',   100002, 22, 'WC',   'ACTIVE', TO_DATE('2024-06-01','YYYY-MM-DD'), TO_DATE('2025-05-31','YYYY-MM-DD'), 9500.00, 1000000, 0);

-- Open a few claims via the migrated procedures (claim_id from seq_claim_id: 900000, 900001).
CALL hartford.open_claim(500000, TO_DATE('2024-08-10','YYYY-MM-DD'), 'COLLISION', 'Rear-end collision on I-84');
CALL hartford.open_claim(500003, TO_DATE('2024-10-02','YYYY-MM-DD'), 'INJURY',    'Slip and fall, warehouse floor');

CALL hartford.post_payment(900000, 1800.00, 'CHECK', 'CHK-88231');
CALL hartford.post_payment(900001, 3200.00, 'ACH',   NULL);
