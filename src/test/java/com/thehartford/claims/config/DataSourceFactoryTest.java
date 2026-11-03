package com.thehartford.claims.config;

import com.zaxxer.hikari.HikariConfig;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.io.InputStream;
import java.util.Map;
import java.util.Properties;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class DataSourceFactoryTest {

    private static Properties appProps() throws IOException {
        Properties p = new Properties();
        try (InputStream in = DataSourceFactoryTest.class.getResourceAsStream("/application.properties")) {
            p.load(in);
        }
        return p;
    }

    @Test
    void applicationPropertiesTargetSnowflake() throws IOException {
        Properties p = appProps();
        assertEquals("net.snowflake.client.jdbc.SnowflakeDriver", p.getProperty("db.driver"));
        assertTrue(p.getProperty("db.url").startsWith("jdbc:snowflake://"));
        assertNull(p.getProperty("db.tns.admin"));
        assertNull(p.getProperty("db.pool.connectionInitSql"));
    }

    @Test
    void passwordAuthSetsSnowflakeSessionProperties() throws IOException {
        HikariConfig cfg = DataSourceFactory.buildConfig(appProps(),
            Map.of(DataSourceFactory.ENV_PASSWORD, "pw"));

        Properties ds = cfg.getDataSourceProperties();
        assertEquals("CLAIMS_WH", ds.getProperty("warehouse"));
        assertEquals("HARTFORD", ds.getProperty("db"));
        assertEquals("CLAIMS", ds.getProperty("schema"));
        assertEquals("CLAIMS_APP_RW", ds.getProperty("role"));
        assertEquals("TIMESTAMP_NTZ", ds.getProperty("CLIENT_TIMESTAMP_TYPE_MAPPING"));
        assertEquals("JSON", ds.getProperty("JDBC_QUERY_RESULT_FORMAT"));
        assertEquals("true", ds.getProperty("CLIENT_RESULT_COLUMN_CASE_INSENSITIVE"));
        assertEquals("pw", cfg.getPassword());
        assertFalse(ds.containsKey("oracle.jdbc.implicitStatementCacheSize"));
        assertFalse(ds.containsKey("defaultRowPrefetch"));
        assertNull(cfg.getConnectionInitSql());
    }

    @Test
    void keyPairAuthWhenPrivateKeyFileSet() throws IOException {
        HikariConfig cfg = DataSourceFactory.buildConfig(appProps(), Map.of(
            DataSourceFactory.ENV_PRIVATE_KEY_FILE, "/secrets/rsa_key.p8",
            DataSourceFactory.ENV_PRIVATE_KEY_FILE_PWD, "kp"));

        Properties ds = cfg.getDataSourceProperties();
        assertEquals("SNOWFLAKE_JWT", ds.getProperty("authenticator"));
        assertEquals("/secrets/rsa_key.p8", ds.getProperty("private_key_file"));
        assertEquals("kp", ds.getProperty("private_key_file_pwd"));
        assertNull(cfg.getPassword());
    }

    @Test
    void missingCredentialsFailFast() {
        assertThrows(IllegalStateException.class,
            () -> DataSourceFactory.buildConfig(appProps(), Map.of()));
    }
}
