--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Oracle 19c physical schema (DDL)
--
-- Domain: Property & Casualty policy administration + claims processing.
-- NOTE (migration): this file is intentionally full of Oracle-isms that do NOT
-- port 1:1 to Snowflake. See docs/MIGRATION.md.
--
-- PII: customer.ssn and customer.date_of_birth are regulated PII and are stored
-- with TDE column encryption; non-privileged sessions additionally see redacted
-- values via the DBMS_REDACT policy at the bottom of this file. TDE column
-- encryption requires an open keystore before this script runs, e.g.:
--
--   ADMINISTER KEY MANAGEMENT CREATE KEYSTORE '/u01/app/oracle/admin/HRTFD/wallet'
--     IDENTIFIED BY "<keystore-password>";
--   ADMINISTER KEY MANAGEMENT SET KEYSTORE OPEN IDENTIFIED BY "<keystore-password>";
--   ADMINISTER KEY MANAGEMENT SET KEY IDENTIFIED BY "<keystore-password>"
--     WITH BACKUP;
--------------------------------------------------------------------------------

-- Dedicated schema / tablespace assignment (Snowflake has no tablespaces).
CREATE TABLESPACE hartford_data
  DATAFILE '/u01/oradata/HRTFD/hartford_data01.dbf' SIZE 512M AUTOEXTEND ON;

ALTER SESSION SET CURRENT_SCHEMA = HARTFORD;

--------------------------------------------------------------------------------
-- Sequences (Snowflake: use CREATE SEQUENCE or IDENTITY columns; no .NEXTVAL/.CURRVAL)
--------------------------------------------------------------------------------
CREATE SEQUENCE hartford.seq_customer_id  START WITH 100000 INCREMENT BY 1 CACHE 50;
CREATE SEQUENCE hartford.seq_policy_id     START WITH 500000 INCREMENT BY 1 CACHE 50;
CREATE SEQUENCE hartford.seq_claim_id      START WITH 900000 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE hartford.seq_payment_id    START WITH 1       INCREMENT BY 1 CACHE 100;

--------------------------------------------------------------------------------
-- CUSTOMER
--------------------------------------------------------------------------------
CREATE TABLE hartford.customer (
  customer_id      NUMBER(12)        NOT NULL,
  first_name       VARCHAR2(60 CHAR),
  last_name        VARCHAR2(60 CHAR),
  -- Regulated PII: encrypted at rest with TDE (NO SALT on ssn so equality
  -- lookups on it remain indexable).
  ssn              VARCHAR2(11 BYTE) ENCRYPT USING 'AES256' NO SALT,
  date_of_birth    DATE              ENCRYPT USING 'AES256',
  email            VARCHAR2(120 CHAR),
  phone            VARCHAR2(20 CHAR),
  -- Oracle DATE carries a time component; downstream code relies on it.
  created_ts       DATE              DEFAULT SYSDATE NOT NULL,
  updated_ts       DATE              DEFAULT SYSDATE NOT NULL,
  risk_score       NUMBER,                       -- unconstrained NUMBER (float-ish)
  lifetime_premium NUMBER(14,2)      DEFAULT 0,
  notes            CLOB,
  CONSTRAINT pk_customer PRIMARY KEY (customer_id)
) TABLESPACE hartford_data;

--------------------------------------------------------------------------------
-- AGENT  (self-referencing hierarchy -> demoed with CONNECT BY elsewhere)
--------------------------------------------------------------------------------
CREATE TABLE hartford.agent (
  agent_id         NUMBER(10)   NOT NULL,
  agent_name       VARCHAR2(120 CHAR),
  manager_id       NUMBER(10),                   -- FK to agent_id (org chart)
  region_code      VARCHAR2(4 CHAR),
  hire_date        DATE,
  CONSTRAINT pk_agent PRIMARY KEY (agent_id),
  CONSTRAINT fk_agent_mgr FOREIGN KEY (manager_id) REFERENCES hartford.agent (agent_id)
) TABLESPACE hartford_data;

--------------------------------------------------------------------------------
-- POLICY
--------------------------------------------------------------------------------
CREATE TABLE hartford.policy (
  policy_id        NUMBER(12)    NOT NULL,
  policy_number    VARCHAR2(20 CHAR) NOT NULL,
  customer_id      NUMBER(12)    NOT NULL,
  agent_id         NUMBER(10),
  product_code     VARCHAR2(10 CHAR),            -- AUTO / HOME / UMBRELLA / WC
  status           VARCHAR2(12 CHAR) DEFAULT 'ACTIVE',
  effective_date   DATE          NOT NULL,
  expiration_date  DATE          NOT NULL,
  annual_premium   NUMBER(12,2)  NOT NULL,
  coverage_limit   NUMBER(14,2),
  deductible       NUMBER(10,2),
  created_ts       DATE          DEFAULT SYSDATE NOT NULL,
  CONSTRAINT pk_policy PRIMARY KEY (policy_id),
  CONSTRAINT uq_policy_number UNIQUE (policy_number),
  CONSTRAINT fk_policy_cust FOREIGN KEY (customer_id) REFERENCES hartford.customer (customer_id),
  CONSTRAINT fk_policy_agent FOREIGN KEY (agent_id) REFERENCES hartford.agent (agent_id),
  CONSTRAINT ck_policy_status CHECK (status IN ('ACTIVE','LAPSED','CANCELLED','PENDING'))
) TABLESPACE hartford_data;

--------------------------------------------------------------------------------
-- CLAIM
--------------------------------------------------------------------------------
CREATE TABLE hartford.claim (
  claim_id         NUMBER(12)    NOT NULL,
  claim_number     VARCHAR2(24 CHAR) NOT NULL,
  policy_id        NUMBER(12)    NOT NULL,
  loss_date        DATE          NOT NULL,
  reported_date    DATE          DEFAULT SYSDATE NOT NULL,
  claim_type       VARCHAR2(20 CHAR),
  status           VARCHAR2(16 CHAR) DEFAULT 'OPEN',
  reserve_amount   NUMBER(14,2)  DEFAULT 0,
  paid_amount      NUMBER(14,2)  DEFAULT 0,
  adjuster_id      NUMBER(10),
  description      VARCHAR2(4000 CHAR),
  CONSTRAINT pk_claim PRIMARY KEY (claim_id),
  CONSTRAINT uq_claim_number UNIQUE (claim_number),
  CONSTRAINT fk_claim_policy FOREIGN KEY (policy_id) REFERENCES hartford.policy (policy_id),
  CONSTRAINT ck_claim_status CHECK (status IN ('OPEN','INVESTIGATING','APPROVED','DENIED','CLOSED'))
) TABLESPACE hartford_data;

--------------------------------------------------------------------------------
-- CLAIM_PAYMENT
--------------------------------------------------------------------------------
CREATE TABLE hartford.claim_payment (
  payment_id       NUMBER(14)    NOT NULL,
  claim_id         NUMBER(12)    NOT NULL,
  payment_date     DATE          DEFAULT SYSDATE NOT NULL,
  amount           NUMBER(14,2)  NOT NULL,
  payment_method   VARCHAR2(16 CHAR),
  check_number     VARCHAR2(20 CHAR),
  CONSTRAINT pk_payment PRIMARY KEY (payment_id),
  CONSTRAINT fk_payment_claim FOREIGN KEY (claim_id) REFERENCES hartford.claim (claim_id)
) TABLESPACE hartford_data;

--------------------------------------------------------------------------------
-- Indexes
--------------------------------------------------------------------------------
CREATE INDEX hartford.ix_policy_customer ON hartford.policy (customer_id) TABLESPACE hartford_data;
CREATE INDEX hartford.ix_claim_policy    ON hartford.claim (policy_id)    TABLESPACE hartford_data;
CREATE INDEX hartford.ix_claim_status    ON hartford.claim (status)       TABLESPACE hartford_data;
-- Function-based index (Snowflake has no function-based indexes; drop or re-model)
CREATE INDEX hartford.ix_cust_upper_name ON hartford.customer (UPPER(last_name)) TABLESPACE hartford_data;

--------------------------------------------------------------------------------
-- PII protection: least-privilege grants + redaction
--
-- Only holders of hartford_pii_reader may see plaintext ssn / date_of_birth.
-- Everything else (reporting users, the nightly flat-file extract, ad-hoc DBA
-- queries that lack EXEMPT REDACTION POLICY) reads masked values.
-- Snowflake equivalent: CREATE MASKING POLICY + ALTER TABLE ... SET MASKING
-- POLICY, applied to the same two columns. See docs/MIGRATION.md.
--------------------------------------------------------------------------------
CREATE ROLE hartford_customer_reader;   -- non-PII read access
CREATE ROLE hartford_pii_reader;        -- cleartext PII read access

-- Column-level SELECT: PII columns are not part of the general read grant.
GRANT SELECT (customer_id, first_name, last_name, email, phone,
              created_ts, updated_ts, risk_score, lifetime_premium, notes)
  ON hartford.customer TO hartford_customer_reader;
GRANT SELECT ON hartford.customer TO hartford_pii_reader;

BEGIN
  DBMS_REDACT.add_policy(
    object_schema       => 'HARTFORD',
    object_name         => 'CUSTOMER',
    policy_name         => 'RDP_CUSTOMER_PII',
    column_name         => 'SSN',
    function_type       => DBMS_REDACT.regexp,
    regexp_pattern      => '\d{3}-\d{2}-(\d{4})',
    regexp_replace_string => 'XXX-XX-\1',
    regexp_position     => 1,
    regexp_occurrence   => 0,
    -- Redact unless the session holds the PII role.
    expression          => 'SYS_CONTEXT(''SYS_SESSION_ROLES'',''HARTFORD_PII_READER'') = ''FALSE''',
    policy_description  => 'Mask customer SSN/DOB for non-PII roles',
    enable              => TRUE);

  DBMS_REDACT.alter_policy(
    object_schema => 'HARTFORD',
    object_name   => 'CUSTOMER',
    policy_name   => 'RDP_CUSTOMER_PII',
    action        => DBMS_REDACT.add_column,
    column_name   => 'DATE_OF_BIRTH',
    function_type => DBMS_REDACT.full);   -- DOB -> 01-JAN-01
END;
/
