package com.thehartford.claims.config;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Locale;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SqlLibraryTest {

    private static final List<String> STATEMENTS = List.of(
        "agent_org_chart", "monthly_premium", "stale_open_claims",
        "customer_upsert", "high_risk_customers");

    private static final List<Pattern> ORACLE_ONLY = List.of(
        Pattern.compile("\\(\\+\\)"),
        Pattern.compile("\\bROWNUM\\b"),
        Pattern.compile("\\bCONNECT\\s+BY\\b"),
        Pattern.compile("\\bSTART\\s+WITH\\b"),
        Pattern.compile("\\bSYS_CONNECT_BY_PATH\\b"),
        Pattern.compile("\\bSIBLINGS\\b"),
        Pattern.compile("\\bSYSDATE\\b"),
        Pattern.compile("\\bADD_MONTHS\\b"),
        Pattern.compile("\\bTO_CHAR\\b"),
        Pattern.compile("\\bNVL2?\\b"),
        Pattern.compile("\\bDECODE\\b"),
        Pattern.compile("\\bDUAL\\b"),
        Pattern.compile(":\\d+"),
        Pattern.compile("\\bHARTFORD\\."));

    private final SqlLibrary lib = SqlLibrary.fromResource("/sql/reports.sql");

    @Test
    void loadsNamedStatements() {
        STATEMENTS.forEach(name -> assertNotNull(lib.get(name)));
    }

    @Test
    void orgChartQueryUsesRecursiveCte() {
        String sql = lib.get("agent_org_chart").toUpperCase(Locale.ROOT);
        assertTrue(sql.contains("WITH RECURSIVE"));
    }

    @Test
    void statementsContainNoOracleOnlyConstructs() {
        for (String name : STATEMENTS) {
            String sql = lib.get(name).toUpperCase(Locale.ROOT);
            for (Pattern p : ORACLE_ONLY) {
                assertFalse(p.matcher(sql).find(),
                    () -> name + " still contains Oracle construct " + p.pattern());
            }
        }
    }

    @Test
    void customerUpsertUsesFourPositionalBinds() {
        assertTrue(lib.get("customer_upsert").chars().filter(c -> c == '?').count() == 4);
    }

    @Test
    void unknownStatementThrows() {
        assertThrows(IllegalArgumentException.class, () -> lib.get("does_not_exist"));
    }
}
