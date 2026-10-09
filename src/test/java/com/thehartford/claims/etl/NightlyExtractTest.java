package com.thehartford.claims.etl;

import org.junit.jupiter.api.Test;

import java.time.LocalDate;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class NightlyExtractTest {

    private static final LocalDate RUN_DATE = LocalDate.of(2026, 10, 9);

    @Test
    void buildsCopyIntoStageUnload() {
        String sql = NightlyExtract.buildCopySql("@claims_extract_stage/", "psv_format", RUN_DATE);
        assertTrue(sql.startsWith("COPY INTO @claims_extract_stage/claims/2026-10-09/claims_changed_ FROM ("), sql);
        assertTrue(sql.contains("FILE_FORMAT = (FORMAT_NAME = 'psv_format')"));
        assertTrue(sql.endsWith("OVERWRITE = TRUE"));
    }

    @Test
    void windowUsesDateaddInsteadOfTruncSysdate() {
        String q = NightlyExtract.CHANGED_CLAIMS_QUERY;
        assertTrue(q.contains("DATEADD('day', -1, CURRENT_DATE())"));
        assertTrue(q.contains("TO_VARCHAR("));
        assertFalse(q.contains("SYSDATE"));
        assertFalse(q.contains("TO_CHAR("));
        assertFalse(q.contains("hartford."));
    }

    @Test
    void rejectsUnsafeStageOrFormat() {
        assertThrows(IllegalArgumentException.class,
            () -> NightlyExtract.buildCopySql("@s; DROP TABLE claim", "psv_format", RUN_DATE));
        assertThrows(IllegalArgumentException.class,
            () -> NightlyExtract.buildCopySql("claims_extract_stage", "psv_format", RUN_DATE));
        assertThrows(IllegalArgumentException.class,
            () -> NightlyExtract.buildCopySql("@s", "fmt') ; --", RUN_DATE));
        assertEquals(NightlyExtract.buildCopySql("@s", "f", RUN_DATE),
            NightlyExtract.buildCopySql("@s/", "f", RUN_DATE));
    }
}
