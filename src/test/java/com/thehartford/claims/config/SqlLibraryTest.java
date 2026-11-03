package com.thehartford.claims.config;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SqlLibraryTest {

    private static final List<String> NAMES = List.of(
        "agent_org_chart", "monthly_premium", "stale_open_claims",
        "customer_upsert", "high_risk_customers");

    private static final List<Pattern> ORACLE_ONLY = List.of(
        Pattern.compile("CONNECT\\s+BY"),
        Pattern.compile("\\bSTART\\s+WITH\\b"),
        Pattern.compile("SYS_CONNECT_BY_PATH"),
        Pattern.compile("\\bLEVEL\\b"),
        Pattern.compile("\\bROWNUM\\b"),
        Pattern.compile("\\(\\+\\)"),
        Pattern.compile("\\bSYSDATE\\b"),
        Pattern.compile("\\bFROM\\s+DUAL\\b"),
        Pattern.compile("\\bDECODE\\s*\\("),
        Pattern.compile("\\bNVL2?\\s*\\("),
        Pattern.compile("\\bADD_MONTHS\\s*\\("),
        Pattern.compile("\\bTO_CHAR\\s*\\("),
        Pattern.compile(":\\d+"),
        Pattern.compile("\\bHARTFORD\\."));

    private final SqlLibrary lib = SqlLibrary.fromResource("/sql/reports.sql");

    @Test
    void loadsNamedStatements() {
        for (String name : NAMES) {
            assertNotNull(lib.get(name));
        }
    }

    @Test
    void orgChartQueryUsesRecursiveCte() {
        assertTrue(lib.get("agent_org_chart").toUpperCase().contains("WITH RECURSIVE"));
    }

    @Test
    void statementsContainNoOracleOnlySyntax() {
        for (String name : NAMES) {
            String sql = lib.get(name).toUpperCase();
            for (Pattern p : ORACLE_ONLY) {
                assertFalse(p.matcher(sql).find(), name + " still contains " + p.pattern());
            }
        }
    }

    @Test
    void unknownStatementThrows() {
        assertThrows(IllegalArgumentException.class, () -> lib.get("does_not_exist"));
    }
}
