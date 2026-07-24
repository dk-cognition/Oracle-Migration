--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake physical schema (DDL), migrated from db/oracle/01_schema.sql.
--
-- Migration notes:
--   * No tablespaces  -> CREATE TABLESPACE / TABLESPACE clauses removed.
--   * VARCHAR2(n CHAR|BYTE) -> VARCHAR(n).
--   * Unbounded NUMBER -> NUMBER(38,0); risk_score is fractional -> FLOAT.
--   * Oracle DATE carries a time component -> TIMESTAMP_NTZ (never DATE).
--   * CLOB -> VARCHAR.
--   * Sequence + BEFORE INSERT trigger PKs -> IDENTITY/AUTOINCREMENT columns.
--   * created_ts / updated_ts -> DEFAULT CURRENT_TIMESTAMP.
--   * No user indexes -> all CREATE INDEX statements dropped (clustering keys only).
--------------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS hartford;
CREATE SCHEMA   IF NOT EXISTS hartford.claims;

USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- Sequences retained for application-side id peeking (CustomerDao.peekNextId)
-- and for the payment id default. Snowflake sequences are not gap-free.
--------------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS seq_customer_id START WITH 100000 INCREMENT BY 1;
CREATE SEQUENCE IF NOT EXISTS seq_policy_id   START WITH 500000 INCREMENT BY 1;
CREATE SEQUENCE IF NOT EXISTS seq_claim_id    START WITH 900000 INCREMENT BY 1;
CREATE SEQUENCE IF NOT EXISTS seq_payment_id  START WITH 1      INCREMENT BY 1;

--------------------------------------------------------------------------------
-- CUSTOMER
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE customer (
  customer_id      NUMBER(12)    NOT NULL DEFAULT seq_customer_id.NEXTVAL,
  first_name       VARCHAR(60),
  last_name        VARCHAR(60),
  ssn              VARCHAR(11),
  date_of_birth    TIMESTAMP_NTZ,
  email            VARCHAR(120),
  phone            VARCHAR(20),
  created_ts       TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_ts       TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  risk_score       FLOAT,
  lifetime_premium NUMBER(14,2)  DEFAULT 0,
  notes            VARCHAR,
  CONSTRAINT pk_customer PRIMARY KEY (customer_id)
);

--------------------------------------------------------------------------------
-- AGENT (self-referencing hierarchy -> WITH RECURSIVE in reports.sql)
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE agent (
  agent_id    NUMBER(10) NOT NULL,
  agent_name  VARCHAR(120),
  manager_id  NUMBER(10),
  region_code VARCHAR(4),
  hire_date   TIMESTAMP_NTZ,
  CONSTRAINT pk_agent PRIMARY KEY (agent_id),
  CONSTRAINT fk_agent_mgr FOREIGN KEY (manager_id) REFERENCES agent (agent_id)
);

--------------------------------------------------------------------------------
-- POLICY
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE policy (
  policy_id       NUMBER(12)    NOT NULL DEFAULT seq_policy_id.NEXTVAL,
  policy_number   VARCHAR(20)   NOT NULL,
  customer_id     NUMBER(12)    NOT NULL,
  agent_id        NUMBER(10),
  product_code    VARCHAR(10),
  status          VARCHAR(12)   DEFAULT 'ACTIVE',
  effective_date  TIMESTAMP_NTZ NOT NULL,
  expiration_date TIMESTAMP_NTZ NOT NULL,
  annual_premium  NUMBER(12,2)  NOT NULL,
  coverage_limit  NUMBER(14,2),
  deductible      NUMBER(10,2),
  created_ts      TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT pk_policy PRIMARY KEY (policy_id),
  CONSTRAINT uq_policy_number UNIQUE (policy_number),
  CONSTRAINT fk_policy_cust  FOREIGN KEY (customer_id) REFERENCES customer (customer_id),
  CONSTRAINT fk_policy_agent FOREIGN KEY (agent_id)    REFERENCES agent (agent_id),
  CONSTRAINT ck_policy_status CHECK (status IN ('ACTIVE','LAPSED','CANCELLED','PENDING'))
);

--------------------------------------------------------------------------------
-- CLAIM
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE claim (
  claim_id       NUMBER(12)    NOT NULL DEFAULT seq_claim_id.NEXTVAL,
  claim_number   VARCHAR(24)   NOT NULL,
  policy_id      NUMBER(12)    NOT NULL,
  loss_date      TIMESTAMP_NTZ NOT NULL,
  reported_date  TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  claim_type     VARCHAR(20),
  status         VARCHAR(16)   DEFAULT 'OPEN',
  reserve_amount NUMBER(14,2)  DEFAULT 0,
  paid_amount    NUMBER(14,2)  DEFAULT 0,
  adjuster_id    NUMBER(10),
  description    VARCHAR(4000),
  CONSTRAINT pk_claim PRIMARY KEY (claim_id),
  CONSTRAINT uq_claim_number UNIQUE (claim_number),
  CONSTRAINT fk_claim_policy FOREIGN KEY (policy_id) REFERENCES policy (policy_id),
  CONSTRAINT ck_claim_status CHECK (status IN ('OPEN','INVESTIGATING','APPROVED','DENIED','CLOSED'))
);

--------------------------------------------------------------------------------
-- CLAIM_PAYMENT
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE claim_payment (
  payment_id     NUMBER(14)    NOT NULL DEFAULT seq_payment_id.NEXTVAL,
  claim_id       NUMBER(12)    NOT NULL,
  payment_date   TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  amount         NUMBER(14,2)  NOT NULL,
  payment_method VARCHAR(16),
  check_number   VARCHAR(20),
  CONSTRAINT pk_payment PRIMARY KEY (payment_id),
  CONSTRAINT fk_payment_claim FOREIGN KEY (claim_id) REFERENCES claim (claim_id)
);

--------------------------------------------------------------------------------
-- Clustering keys replace the dropped Oracle indexes. Enable only if the tables
-- grow large enough to justify automatic reclustering.
--------------------------------------------------------------------------------
-- ALTER TABLE policy CLUSTER BY (customer_id);
-- ALTER TABLE claim  CLUSTER BY (policy_id, status);
