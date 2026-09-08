package com.thehartford.claims.config;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SqlLibraryTest {

    private final SqlLibrary lib = SqlLibrary.fromResource("/sql/reports.sql");

    @Test
    void loadsNamedStatements() {
        assertNotNull(lib.get("agent_org_chart"));
        assertNotNull(lib.get("monthly_premium"));
        assertNotNull(lib.get("stale_open_claims"));
        assertNotNull(lib.get("customer_upsert"));
        assertNotNull(lib.get("high_risk_customers"));
        assertNotNull(lib.get("changed_claims_export"));
    }

    @Test
    void orgChartQueryUsesRecursiveCte() {
        String orgChart = lib.get("agent_org_chart").toUpperCase();
        assertTrue(orgChart.contains("WITH RECURSIVE"));
        assertFalse(orgChart.contains("CONNECT BY"));
    }

    @Test
    void statementsContainNoOracleOnlyConstructs() {
        for (String name : new String[] {"agent_org_chart", "monthly_premium", "stale_open_claims",
                                         "customer_upsert", "high_risk_customers", "changed_claims_export"}) {
            String s = lib.get(name).toUpperCase();
            assertFalse(s.contains("ROWNUM"), name);
            assertFalse(s.contains("SYSDATE"), name);
            assertFalse(s.contains("FROM DUAL"), name);
            assertFalse(s.contains("(+)"), name);
            assertFalse(s.contains("DECODE("), name);
            assertFalse(s.contains("NVL"), name);
            assertFalse(s.contains("ADD_MONTHS"), name);
        }
    }

    @Test
    void unknownStatementThrows() {
        assertThrows(IllegalArgumentException.class, () -> lib.get("does_not_exist"));
    }
}
