--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake physical schema (DDL)
--
-- Domain: Property & Casualty policy administration + claims processing.
--------------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS hartford;
USE SCHEMA hartford;

--------------------------------------------------------------------------------
-- Keys needed by application/procedure code use explicit sequences and column
-- defaults. Other keys use AUTOINCREMENT because callers do not need the value
-- before or during the insert. Snowflake does not support sequence caching.
--------------------------------------------------------------------------------
CREATE SEQUENCE hartford.seq_customer_id START = 100000 INCREMENT = 1;
CREATE SEQUENCE hartford.seq_claim_id    START = 900000 INCREMENT = 1;

--------------------------------------------------------------------------------
-- Constraints are retained as metadata for documentation and tooling.
-- Snowflake does not enforce PRIMARY KEY, UNIQUE, or FOREIGN KEY constraints
-- on standard tables; NOT NULL remains enforced.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- CUSTOMER
--------------------------------------------------------------------------------
CREATE TABLE hartford.customer (
  customer_id      NUMBER(12)        NOT NULL DEFAULT hartford.seq_customer_id.NEXTVAL,
  first_name       VARCHAR(60),
  last_name        VARCHAR(60),
  ssn              VARCHAR(11),
  date_of_birth    TIMESTAMP_NTZ,
  email            VARCHAR(120),
  phone            VARCHAR(20),
  created_ts       TIMESTAMP_NTZ     DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  updated_ts       TIMESTAMP_NTZ     DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  risk_score       FLOAT,
  lifetime_premium NUMBER(14,2)      DEFAULT 0,
  notes            VARCHAR(16777216),
  CONSTRAINT pk_customer PRIMARY KEY (customer_id)
);

--------------------------------------------------------------------------------
-- AGENT  (self-referencing hierarchy -> recursive CTE in reports.sql)
--------------------------------------------------------------------------------
CREATE TABLE hartford.agent (
  agent_id         NUMBER(10)   NOT NULL,
  agent_name       VARCHAR(120),
  manager_id       NUMBER(10),
  region_code      VARCHAR(4),
  hire_date        TIMESTAMP_NTZ,
  CONSTRAINT pk_agent PRIMARY KEY (agent_id),
  CONSTRAINT fk_agent_mgr FOREIGN KEY (manager_id) REFERENCES hartford.agent (agent_id)
);

--------------------------------------------------------------------------------
-- POLICY
--------------------------------------------------------------------------------
CREATE TABLE hartford.policy (
  policy_id        NUMBER(12)    NOT NULL AUTOINCREMENT START 500000 INCREMENT 1,
  policy_number    VARCHAR(20)   NOT NULL,
  customer_id      NUMBER(12)    NOT NULL,
  agent_id         NUMBER(10),
  product_code     VARCHAR(10),
  status           VARCHAR(12) DEFAULT 'ACTIVE',
  effective_date   TIMESTAMP_NTZ NOT NULL,
  expiration_date  TIMESTAMP_NTZ NOT NULL,
  annual_premium   NUMBER(12,2) NOT NULL,
  coverage_limit   NUMBER(14,2),
  deductible       NUMBER(10,2),
  created_ts       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  CONSTRAINT pk_policy PRIMARY KEY (policy_id),
  CONSTRAINT uq_policy_number UNIQUE (policy_number),
  CONSTRAINT fk_policy_cust FOREIGN KEY (customer_id) REFERENCES hartford.customer (customer_id),
  CONSTRAINT fk_policy_agent FOREIGN KEY (agent_id) REFERENCES hartford.agent (agent_id)
);
-- Snowflake does not support CHECK constraints. The policy status domain must
-- be enforced by the application or a downstream data-quality test.

--------------------------------------------------------------------------------
-- CLAIM
--------------------------------------------------------------------------------
CREATE TABLE hartford.claim (
  claim_id         NUMBER(12)    NOT NULL DEFAULT hartford.seq_claim_id.NEXTVAL,
  claim_number     VARCHAR(24)   NOT NULL,
  policy_id        NUMBER(12)    NOT NULL,
  loss_date        TIMESTAMP_NTZ NOT NULL,
  reported_date    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  claim_type       VARCHAR(20),
  status           VARCHAR(16) DEFAULT 'OPEN',
  reserve_amount   NUMBER(14,2)  DEFAULT 0,
  paid_amount      NUMBER(14,2)  DEFAULT 0,
  adjuster_id      NUMBER(10),
  description      VARCHAR(4000),
  CONSTRAINT pk_claim PRIMARY KEY (claim_id),
  CONSTRAINT uq_claim_number UNIQUE (claim_number),
  CONSTRAINT fk_claim_policy FOREIGN KEY (policy_id) REFERENCES hartford.policy (policy_id)
);
-- Snowflake does not support CHECK constraints. The claim status domain must
-- be enforced by the application or a downstream data-quality test.

--------------------------------------------------------------------------------
-- CLAIM_PAYMENT
--------------------------------------------------------------------------------
CREATE TABLE hartford.claim_payment (
  payment_id       NUMBER(14)    NOT NULL AUTOINCREMENT START 1 INCREMENT 1,
  claim_id         NUMBER(12)    NOT NULL,
  payment_date     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  amount           NUMBER(14,2)  NOT NULL,
  payment_method   VARCHAR(16),
  check_number     VARCHAR(20),
  CONSTRAINT pk_payment PRIMARY KEY (payment_id),
  CONSTRAINT fk_payment_claim FOREIGN KEY (claim_id) REFERENCES hartford.claim (claim_id)
);

--------------------------------------------------------------------------------
-- Snowflake has no user indexes; micro-partitions and, where needed, clustering
-- keys provide the physical access optimization instead.
--------------------------------------------------------------------------------
