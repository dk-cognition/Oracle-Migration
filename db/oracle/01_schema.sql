--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Oracle 19c physical schema (DDL)
--
-- Domain: Property & Casualty policy administration + claims processing.
-- NOTE (migration): this file is intentionally full of Oracle-isms that do NOT
-- port 1:1 to Snowflake. See docs/MIGRATION.md.
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
  ssn              VARCHAR2(11 BYTE),
  date_of_birth    DATE,
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
