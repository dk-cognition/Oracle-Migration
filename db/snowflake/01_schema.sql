--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake physical schema (DDL), migrated from db/oracle/01_schema.sql.
--
-- Migration notes (see docs/MIGRATION.md):
--   * No tablespaces  -> CREATE TABLESPACE / TABLESPACE clauses dropped.
--   * No user indexes -> all CREATE INDEX statements dropped, including the
--     function-based ix_cust_upper_name (use clustering keys if ever needed).
--   * VARCHAR2(n CHAR|BYTE) -> VARCHAR(n).
--   * Unbounded NUMBER -> NUMBER(38,0), or FLOAT where fractional (risk_score).
--   * Oracle DATE (has a time component) -> TIMESTAMP_NTZ.
--   * CLOB -> VARCHAR.
--   * Sequence + BEFORE INSERT trigger key generation -> AUTOINCREMENT /
--     DEFAULT <seq>.NEXTVAL column defaults.
--------------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS hartford;
CREATE SCHEMA IF NOT EXISTS hartford.claims;

USE DATABASE hartford;
USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- Sequences
-- Snowflake sequences have no CACHE/NOCACHE, no CURRVAL and no gap-free
-- guarantee; they are used as column DEFAULTs.
--------------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE hartford.claims.seq_customer_id START WITH 100000 INCREMENT BY 1;
CREATE OR REPLACE SEQUENCE hartford.claims.seq_claim_id   START WITH 900000 INCREMENT BY 1;
CREATE OR REPLACE SEQUENCE hartford.claims.seq_payment_id START WITH 1      INCREMENT BY 1;

--------------------------------------------------------------------------------
-- CUSTOMER
-- customer_id: was seq_customer_id + trg_customer_biu -> DEFAULT seq.NEXTVAL,
-- keeping the named sequence so CustomerDao.peekNextId() still has something to
-- read (an IDENTITY column exposes no next value).
-- created_ts / updated_ts: trigger-maintained -> column DEFAULTs. Snowflake has
-- no row triggers, so "on update" timestamps must be set by the writing
-- statement (see 02_packages.sql / the DAO layer) or by a Stream + Task.
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE hartford.claims.customer (
  customer_id      NUMBER(12)     NOT NULL DEFAULT hartford.claims.seq_customer_id.NEXTVAL,
  first_name       VARCHAR(60),
  last_name        VARCHAR(60),
  ssn              VARCHAR(11),
  date_of_birth    TIMESTAMP_NTZ,
  email            VARCHAR(120),
  phone            VARCHAR(20),
  created_ts       TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  updated_ts       TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  risk_score       FLOAT,
  lifetime_premium NUMBER(14,2)   DEFAULT 0,
  notes            VARCHAR,
  CONSTRAINT pk_customer PRIMARY KEY (customer_id)
);

--------------------------------------------------------------------------------
-- AGENT  (self-referencing hierarchy -> WITH RECURSIVE, see reports.sql)
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE hartford.claims.agent (
  agent_id         NUMBER(10)   NOT NULL,
  agent_name       VARCHAR(120),
  manager_id       NUMBER(10),
  region_code      VARCHAR(4),
  hire_date        TIMESTAMP_NTZ,
  CONSTRAINT pk_agent PRIMARY KEY (agent_id),
  CONSTRAINT fk_agent_mgr FOREIGN KEY (manager_id) REFERENCES hartford.claims.agent (agent_id)
);

--------------------------------------------------------------------------------
-- POLICY  (policy_id: was seq_policy_id + trg_policy_bi -> AUTOINCREMENT)
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE hartford.claims.policy (
  policy_id        NUMBER(12)    NOT NULL AUTOINCREMENT(500000, 1),
  policy_number    VARCHAR(20)   NOT NULL,
  customer_id      NUMBER(12)    NOT NULL,
  agent_id         NUMBER(10),
  product_code     VARCHAR(10),
  status           VARCHAR(12)   DEFAULT 'ACTIVE',
  effective_date   TIMESTAMP_NTZ NOT NULL,
  expiration_date  TIMESTAMP_NTZ NOT NULL,
  annual_premium   NUMBER(12,2)  NOT NULL,
  coverage_limit   NUMBER(14,2),
  deductible       NUMBER(10,2),
  created_ts       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  CONSTRAINT pk_policy PRIMARY KEY (policy_id),
  CONSTRAINT uq_policy_number UNIQUE (policy_number),
  CONSTRAINT fk_policy_cust FOREIGN KEY (customer_id) REFERENCES hartford.claims.customer (customer_id),
  CONSTRAINT fk_policy_agent FOREIGN KEY (agent_id) REFERENCES hartford.claims.agent (agent_id)
  -- CHECK constraints are not enforced by Snowflake; status values are validated
  -- in the application / procedure layer instead of ck_policy_status.
);

--------------------------------------------------------------------------------
-- CLAIM
-- claim_id keeps an explicit sequence default so open_claim() can build the
-- claim_number from the same generated id.
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE hartford.claims.claim (
  claim_id         NUMBER(12)    NOT NULL DEFAULT hartford.claims.seq_claim_id.NEXTVAL,
  claim_number     VARCHAR(24)   NOT NULL,
  policy_id        NUMBER(12)    NOT NULL,
  loss_date        TIMESTAMP_NTZ NOT NULL,
  reported_date    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  claim_type       VARCHAR(20),
  status           VARCHAR(16)   DEFAULT 'OPEN',
  reserve_amount   NUMBER(14,2)  DEFAULT 0,
  paid_amount      NUMBER(14,2)  DEFAULT 0,
  adjuster_id      NUMBER(10),
  description      VARCHAR(4000),
  CONSTRAINT pk_claim PRIMARY KEY (claim_id),
  CONSTRAINT uq_claim_number UNIQUE (claim_number),
  CONSTRAINT fk_claim_policy FOREIGN KEY (policy_id) REFERENCES hartford.claims.policy (policy_id)
  -- ck_claim_status dropped: Snowflake does not enforce CHECK constraints.
);

--------------------------------------------------------------------------------
-- CLAIM_PAYMENT
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE hartford.claims.claim_payment (
  payment_id       NUMBER(14)    NOT NULL DEFAULT hartford.claims.seq_payment_id.NEXTVAL,
  claim_id         NUMBER(12)    NOT NULL,
  payment_date     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  amount           NUMBER(14,2)  NOT NULL,
  payment_method   VARCHAR(16),
  check_number     VARCHAR(20),
  CONSTRAINT pk_payment PRIMARY KEY (payment_id),
  CONSTRAINT fk_payment_claim FOREIGN KEY (claim_id) REFERENCES hartford.claims.claim (claim_id)
);

--------------------------------------------------------------------------------
-- Indexes
-- None. Snowflake has no user-defined indexes; ix_policy_customer,
-- ix_claim_policy, ix_claim_status and the function-based ix_cust_upper_name
-- are all dropped. Micro-partition pruning covers these access paths; add a
-- clustering key only if a table grows large and pruning proves insufficient:
--   ALTER TABLE hartford.claims.claim CLUSTER BY (status, policy_id);
--------------------------------------------------------------------------------
