--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake physical schema (DDL), migrated from db/oracle/01_schema.sql.
--
-- Type mapping applied (docs/MIGRATION.md section 1):
--   VARCHAR2(n CHAR|BYTE) -> VARCHAR(n)
--   NUMBER (unbounded)    -> NUMBER(38,0), except risk_score -> FLOAT
--   DATE                  -> TIMESTAMP_NTZ (Oracle DATE carries a time part)
--   CLOB                  -> VARCHAR
-- Dropped: CREATE TABLESPACE / TABLESPACE clauses, every CREATE INDEX
-- (including the function-based ix_cust_upper_name) - Snowflake is
-- storage-managed and has no user indexes.
--------------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS hartford;
CREATE SCHEMA IF NOT EXISTS hartford.claims;

USE DATABASE hartford;
USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- Sequences. Snowflake sequences are not gap-free and have no CACHE/NOCACHE,
-- CURRVAL, or per-session NEXTVAL guarantees; they are consumed via column
-- DEFAULTs below instead of BEFORE INSERT triggers.
--------------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS hartford.claims.seq_customer_id START = 100000 INCREMENT = 1;
CREATE SEQUENCE IF NOT EXISTS hartford.claims.seq_policy_id   START = 500000 INCREMENT = 1;
CREATE SEQUENCE IF NOT EXISTS hartford.claims.seq_claim_id     START = 900000 INCREMENT = 1;
CREATE SEQUENCE IF NOT EXISTS hartford.claims.seq_payment_id   START = 1      INCREMENT = 1;

--------------------------------------------------------------------------------
-- CUSTOMER
-- trg_customer_biu replaced by: PK DEFAULT seq_customer_id.NEXTVAL and
-- DEFAULT CURRENT_TIMESTAMP on both timestamps. The "on update" refresh of
-- updated_ts is handled by the writing statement or the Stream+Task in
-- 04_streams_tasks.sql.
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE hartford.claims.customer (
  customer_id      NUMBER(12)     NOT NULL DEFAULT hartford.claims.seq_customer_id.NEXTVAL,
  first_name       VARCHAR(60),
  last_name        VARCHAR(60),
  ssn              VARCHAR(11),
  date_of_birth    TIMESTAMP_NTZ,
  email            VARCHAR(120),
  phone            VARCHAR(20),
  created_ts       TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  updated_ts       TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  risk_score       FLOAT,
  lifetime_premium NUMBER(14,2)   DEFAULT 0,
  notes            VARCHAR,
  CONSTRAINT pk_customer PRIMARY KEY (customer_id)
);

--------------------------------------------------------------------------------
-- AGENT (self-referencing hierarchy - queried with a recursive CTE)
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE hartford.claims.agent (
  agent_id    NUMBER(10) NOT NULL,
  agent_name  VARCHAR(120),
  manager_id  NUMBER(10),
  region_code VARCHAR(4),
  hire_date   TIMESTAMP_NTZ,
  CONSTRAINT pk_agent PRIMARY KEY (agent_id),
  CONSTRAINT fk_agent_mgr FOREIGN KEY (manager_id) REFERENCES hartford.claims.agent (agent_id)
);

--------------------------------------------------------------------------------
-- POLICY (trg_policy_bi replaced by the policy_id DEFAULT below)
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE hartford.claims.policy (
  policy_id       NUMBER(12)   NOT NULL DEFAULT hartford.claims.seq_policy_id.NEXTVAL,
  policy_number   VARCHAR(20)  NOT NULL,
  customer_id     NUMBER(12)   NOT NULL,
  agent_id        NUMBER(10),
  product_code    VARCHAR(10),
  status          VARCHAR(12)  DEFAULT 'ACTIVE',
  effective_date  TIMESTAMP_NTZ NOT NULL,
  expiration_date TIMESTAMP_NTZ NOT NULL,
  annual_premium  NUMBER(12,2) NOT NULL,
  coverage_limit  NUMBER(14,2),
  deductible      NUMBER(10,2),
  created_ts      TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_policy PRIMARY KEY (policy_id),
  CONSTRAINT uq_policy_number UNIQUE (policy_number),
  CONSTRAINT fk_policy_cust FOREIGN KEY (customer_id) REFERENCES hartford.claims.customer (customer_id),
  CONSTRAINT fk_policy_agent FOREIGN KEY (agent_id) REFERENCES hartford.claims.agent (agent_id)
);

--------------------------------------------------------------------------------
-- CLAIM
-- Snowflake parses CHECK constraints but does not enforce them, so the Oracle
-- ck_claim_status / ck_policy_status domains are enforced by the procedures in
-- 02_procedures.sql and by the load pipeline instead.
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE hartford.claims.claim (
  claim_id       NUMBER(12)   NOT NULL DEFAULT hartford.claims.seq_claim_id.NEXTVAL,
  claim_number   VARCHAR(24)  NOT NULL,
  policy_id      NUMBER(12)   NOT NULL,
  loss_date      TIMESTAMP_NTZ NOT NULL,
  reported_date  TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  claim_type     VARCHAR(20),
  status         VARCHAR(16)  DEFAULT 'OPEN',
  reserve_amount NUMBER(14,2) DEFAULT 0,
  paid_amount    NUMBER(14,2) DEFAULT 0,
  adjuster_id    NUMBER(10),
  description    VARCHAR(4000),
  CONSTRAINT pk_claim PRIMARY KEY (claim_id),
  CONSTRAINT uq_claim_number UNIQUE (claim_number),
  CONSTRAINT fk_claim_policy FOREIGN KEY (policy_id) REFERENCES hartford.claims.policy (policy_id)
);

--------------------------------------------------------------------------------
-- CLAIM_PAYMENT
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE hartford.claims.claim_payment (
  payment_id     NUMBER(14)   NOT NULL DEFAULT hartford.claims.seq_payment_id.NEXTVAL,
  claim_id       NUMBER(12)   NOT NULL,
  payment_date   TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  amount         NUMBER(14,2) NOT NULL,
  payment_method VARCHAR(16),
  check_number   VARCHAR(20),
  CONSTRAINT pk_payment PRIMARY KEY (payment_id),
  CONSTRAINT fk_payment_claim FOREIGN KEY (claim_id) REFERENCES hartford.claims.claim (claim_id)
);

--------------------------------------------------------------------------------
-- Configuration replacing the claims_pkg.g_default_reserve package constant.
-- Read through hartford.claims.fn_default_reserve() (02_procedures.sql).
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE hartford.claims.claims_config (
  config_key   VARCHAR(60) NOT NULL,
  config_value VARCHAR(200) NOT NULL,
  CONSTRAINT pk_claims_config PRIMARY KEY (config_key)
);

INSERT INTO hartford.claims.claims_config (config_key, config_value)
VALUES ('DEFAULT_RESERVE', '2500');

--------------------------------------------------------------------------------
-- Clustering replaces the dropped access-path indexes on the large tables.
-- (ix_policy_customer, ix_claim_policy, ix_claim_status, ix_cust_upper_name.)
--------------------------------------------------------------------------------
ALTER TABLE hartford.claims.policy CLUSTER BY (customer_id);
ALTER TABLE hartford.claims.claim  CLUSTER BY (policy_id, status);
