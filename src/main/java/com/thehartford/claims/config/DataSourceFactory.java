package com.thehartford.claims.config;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

import javax.sql.DataSource;
import java.io.IOException;
import java.io.InputStream;
import java.util.Map;
import java.util.Properties;

/**
 * Builds the application {@link DataSource} (Snowflake via HikariCP) from
 * application.properties.
 *
 * <p>Warehouse, database, schema and role are passed as Snowflake connection
 * properties, replacing Oracle's TNS descriptor and
 * {@code ALTER SESSION SET CURRENT_SCHEMA} init SQL. Authentication uses
 * key-pair when {@code SNOWFLAKE_PRIVATE_KEY_FILE} is set, otherwise
 * {@code SNOWFLAKE_APP_PASSWORD}.</p>
 */
public final class DataSourceFactory {

    static final String ENV_PASSWORD = "SNOWFLAKE_APP_PASSWORD";
    static final String ENV_PRIVATE_KEY_FILE = "SNOWFLAKE_PRIVATE_KEY_FILE";
    static final String ENV_PRIVATE_KEY_FILE_PWD = "SNOWFLAKE_PRIVATE_KEY_FILE_PWD";

    private static volatile HikariDataSource INSTANCE;

    private DataSourceFactory() {
    }

    public static DataSource get() {
        if (INSTANCE == null) {
            synchronized (DataSourceFactory.class) {
                if (INSTANCE == null) {
                    INSTANCE = new HikariDataSource(
                        buildConfig(load("/application.properties"), System.getenv()));
                }
            }
        }
        return INSTANCE;
    }

    static HikariConfig buildConfig(Properties props, Map<String, String> env) {
        HikariConfig cfg = new HikariConfig();
        cfg.setDriverClassName(props.getProperty("db.driver"));
        cfg.setJdbcUrl(props.getProperty("db.url"));
        cfg.setUsername(props.getProperty("db.username"));
        cfg.setMaximumPoolSize(Integer.parseInt(props.getProperty("db.pool.maxSize", "10")));

        putIfPresent(cfg, "warehouse", props.getProperty("db.warehouse"));
        putIfPresent(cfg, "db", props.getProperty("db.database"));
        putIfPresent(cfg, "schema", props.getProperty("db.schema"));
        putIfPresent(cfg, "role", props.getProperty("db.role"));

        // Bind java.sql.Timestamp as TIMESTAMP_NTZ to match the migrated
        // Oracle DATE columns (no time-zone shift on write).
        cfg.addDataSourceProperty("CLIENT_TIMESTAMP_TYPE_MAPPING", "TIMESTAMP_NTZ");
        // The default Arrow result format needs --add-opens java.base/java.nio on
        // JDK 17+; JSON works on any JDK without extra JVM flags.
        cfg.addDataSourceProperty("JDBC_QUERY_RESULT_FORMAT", "JSON");
        // Snowflake returns unquoted identifiers upper-cased; the DAOs read
        // columns by their lower-case names, as they did on Oracle.
        cfg.addDataSourceProperty("CLIENT_RESULT_COLUMN_CASE_INSENSITIVE", "true");

        String keyFile = env.get(ENV_PRIVATE_KEY_FILE);
        if (keyFile != null && !keyFile.isEmpty()) {
            cfg.addDataSourceProperty("authenticator", "SNOWFLAKE_JWT");
            cfg.addDataSourceProperty("private_key_file", keyFile);
            String keyPwd = env.get(ENV_PRIVATE_KEY_FILE_PWD);
            if (keyPwd != null && !keyPwd.isEmpty()) {
                // The JDK alone cannot decrypt PBES2-encrypted PKCS#8 keys.
                System.setProperty("net.snowflake.jdbc.enableBouncyCastle", "true");
            }
            putIfPresent(cfg, "private_key_file_pwd", keyPwd);
        } else {
            String pw = env.get(ENV_PASSWORD);
            if (pw == null || pw.isEmpty()) {
                throw new IllegalStateException(
                    "Set " + ENV_PRIVATE_KEY_FILE + " or " + ENV_PASSWORD
                        + "; cannot connect to Snowflake.");
            }
            cfg.setPassword(pw);
        }
        return cfg;
    }

    private static void putIfPresent(HikariConfig cfg, String key, String value) {
        if (value != null && !value.isEmpty()) {
            cfg.addDataSourceProperty(key, value);
        }
    }

    private static Properties load(String resource) {
        Properties props = new Properties();
        try (InputStream in = DataSourceFactory.class.getResourceAsStream(resource)) {
            if (in == null) {
                throw new IllegalStateException("Missing resource: " + resource);
            }
            props.load(in);
            return props;
        } catch (IOException e) {
            throw new IllegalStateException("Failed to load " + resource, e);
        }
    }
}
