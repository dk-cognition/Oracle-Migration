package com.thehartford.claims.etl;

import org.junit.jupiter.api.Test;

import java.time.LocalDate;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class NightlyExtractTest {

    private static final LocalDate RUN_DATE = LocalDate.of(2026, 11, 3);

    @Test
    void buildsCopyIntoStageForRunDate() {
        String sql = NightlyExtract.buildCopySql("@claims_extract_stage/claims/", RUN_DATE);
        assertTrue(sql.startsWith("COPY INTO @claims_extract_stage/claims/2026-11-03/claims_ FROM ("));
        assertTrue(sql.contains("FORMAT_NAME = 'claims_psv_ff'"));
        assertTrue(sql.contains("DATEADD('day', -1, CURRENT_DATE())"));
        assertFalse(sql.toUpperCase().contains("SYSDATE"));
        assertFalse(sql.toUpperCase().contains("TO_CHAR("));
    }

    @Test
    void rejectsUnsafeStageLocation() {
        assertThrows(IllegalArgumentException.class,
            () -> NightlyExtract.buildCopySql("@stage; DROP TABLE claim", RUN_DATE));
        assertThrows(IllegalArgumentException.class,
            () -> NightlyExtract.buildCopySql("/tmp/claims", RUN_DATE));
    }
}
