package com.thehartford.claims.etl;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

class NightlyExtractTest {

    @Test
    void nullBecomesEmptyField() {
        assertEquals("", NightlyExtract.encodeField(null));
    }

    @Test
    void plainValueIsUnchanged() {
        assertEquals("CLM-2024-0001", NightlyExtract.encodeField("CLM-2024-0001"));
    }

    @Test
    void delimiterIsQuoted() {
        assertEquals("\"a|b\"", NightlyExtract.encodeField("a|b"));
    }

    @Test
    void lineBreaksAreQuoted() {
        assertEquals("\"a\r\nb\"", NightlyExtract.encodeField("a\r\nb"));
    }

    @Test
    void embeddedQuotesAreDoubled() {
        assertEquals("\"say \"\"hi\"\"|now\"", NightlyExtract.encodeField("say \"hi\"|now"));
    }
}
