package com.thehartford.claims.config;

import org.junit.jupiter.api.Test;

import java.util.Properties;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

class DataSourceFactoryTest {

    @Test
    void buildsSnowflakeUrlFromApplicationProperties() {
        Properties props = DataSourceFactory.load("/application.properties");
        assertEquals("net.snowflake.client.jdbc.SnowflakeDriver", props.getProperty("db.driver"));
        assertEquals(
            "jdbc:snowflake://hartford.us-east-1.snowflakecomputing.com/"
                + "?warehouse=CLAIMS_WH&db=HARTFORD&schema=CLAIMS&role=CLAIMS_APP_RW",
            DataSourceFactory.buildJdbcUrl(props));
    }

    @Test
    void applicationPropertiesHaveNoOracleSettings() {
        Properties props = DataSourceFactory.load("/application.properties");
        assertNull(props.getProperty("db.tns.admin"));
        assertNull(props.getProperty("db.pool.connectionInitSql"));
        props.stringPropertyNames().forEach(k ->
            assertEquals(-1, props.getProperty(k).toLowerCase().indexOf("oracle"), k));
    }

    @Test
    void omitsBlankParamsAndEncodesValues() {
        Properties props = new Properties();
        props.setProperty("db.account", "acme-prod");
        props.setProperty("db.warehouse", "WH 1");
        props.setProperty("db.role", "");
        assertEquals("jdbc:snowflake://acme-prod.snowflakecomputing.com/?warehouse=WH+1",
            DataSourceFactory.buildJdbcUrl(props));
    }

    @Test
    void explicitUrlWins() {
        Properties props = new Properties();
        props.setProperty("db.url", "jdbc:snowflake://x.snowflakecomputing.com/?db=D");
        props.setProperty("db.account", "ignored");
        assertEquals("jdbc:snowflake://x.snowflakecomputing.com/?db=D", DataSourceFactory.buildJdbcUrl(props));
    }

    @Test
    void missingAccountFails() {
        assertThrows(IllegalStateException.class, () -> DataSourceFactory.buildJdbcUrl(new Properties()));
    }

    @Test
    void tnsnamesIsGone() {
        assertNull(DataSourceFactory.class.getResource("/tnsnames.ora"));
    }
}
