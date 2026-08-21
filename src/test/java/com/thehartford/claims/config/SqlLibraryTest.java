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
    }

    @Test
    void orgChartQueryUsesRecursiveCte() {
        String orgChart = lib.get("agent_org_chart").toUpperCase();
        assertTrue(orgChart.contains("WITH RECURSIVE"));
        assertFalse(orgChart.contains("CONNECT BY"));
    }

    @Test
    void statementsContainNoOracleOnlyConstructs() {
        for (String name : new String[] {"agent_org_chart", "monthly_premium",
                                         "stale_open_claims", "customer_upsert",
                                         "high_risk_customers"}) {
            String sql = lib.get(name).toUpperCase();
            for (String oracleism : new String[] {"ROWNUM", "SYSDATE", "DECODE(", "NVL(",
                                                  "NVL2(", "ADD_MONTHS(", "FROM DUAL",
                                                  "SYS_CONNECT_BY_PATH"}) {
                assertFalse(sql.contains(oracleism),
                    name + " still contains the Oracle construct " + oracleism);
            }
        }
    }

    @Test
    void unknownStatementThrows() {
        assertThrows(IllegalArgumentException.class, () -> lib.get("does_not_exist"));
    }
}
