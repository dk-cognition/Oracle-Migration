package com.thehartford.claims.config;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

import javax.sql.DataSource;
import java.io.IOException;
import java.io.InputStream;
import java.util.Properties;

/**
 * Builds the application {@link DataSource} from application.properties.
 *
 * <p>Snowflake datasource: the account URL comes from {@code db.url} and the
 * session context (warehouse, database, schema, role) is passed as driver
 * connection properties. There is no TNS resolution and no vendor statement
 * cache / row prefetch tuning; Snowflake manages both. See docs/MIGRATION.md.</p>
 */
public final class DataSourceFactory {

    private static volatile HikariDataSource INSTANCE;

    private DataSourceFactory() {
    }

    public static DataSource get() {
        if (INSTANCE == null) {
            synchronized (DataSourceFactory.class) {
                if (INSTANCE == null) {
                    INSTANCE = build();
                }
            }
        }
        return INSTANCE;
    }

    private static HikariDataSource build() {
        Properties props = load("/application.properties");

        HikariConfig cfg = new HikariConfig();
        cfg.setDriverClassName(props.getProperty("db.driver"));
        cfg.setJdbcUrl(props.getProperty("db.url"));
        cfg.setUsername(props.getProperty("db.username"));
        cfg.setPassword(resolvePassword());
        cfg.setMaximumPoolSize(Integer.parseInt(props.getProperty("db.pool.maxSize", "10")));

        String initSql = props.getProperty("db.pool.connectionInitSql");
        if (initSql != null) {
            cfg.setConnectionInitSql(initSql);
        }

        // Snowflake session context, applied by the driver at connect time.
        addIfPresent(cfg, props, "warehouse", "db.warehouse");
        addIfPresent(cfg, props, "db", "db.database");
        addIfPresent(cfg, props, "schema", "db.schema");
        addIfPresent(cfg, props, "role", "db.role");

        return new HikariDataSource(cfg);
    }

    private static void addIfPresent(HikariConfig cfg, Properties props,
                                     String driverProperty, String key) {
        String value = props.getProperty(key);
        if (value != null && !value.isEmpty()) {
            cfg.addDataSourceProperty(driverProperty, value);
        }
    }

    private static String resolvePassword() {
        String pw = System.getenv("SNOWFLAKE_APP_PASSWORD");
        if (pw == null || pw.isEmpty()) {
            throw new IllegalStateException(
                "SNOWFLAKE_APP_PASSWORD is not set; cannot connect to Snowflake.");
        }
        return pw;
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
