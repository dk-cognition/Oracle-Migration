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
 * <p>Targets Snowflake: the account URL comes from {@code db.url} and the
 * warehouse / database / schema / role are passed as Snowflake JDBC connection
 * properties so every pooled connection lands in {@code HARTFORD.CLAIMS} without
 * an init statement.</p>
 */
public final class DataSourceFactory {

    static final String PASSWORD_ENV = "SNOWFLAKE_APP_PASSWORD";

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

        addIfPresent(cfg, props, "db.warehouse", "warehouse");
        addIfPresent(cfg, props, "db.database", "db");
        addIfPresent(cfg, props, "db.schema", "schema");
        addIfPresent(cfg, props, "db.role", "role");
        cfg.addDataSourceProperty("application", "hartford-claims-datastore");

        String initSql = props.getProperty("db.pool.connectionInitSql");
        if (initSql != null) {
            cfg.setConnectionInitSql(initSql);
        }

        return new HikariDataSource(cfg);
    }

    private static void addIfPresent(HikariConfig cfg, Properties props, String key, String dsProp) {
        String value = props.getProperty(key);
        if (value != null && !value.isEmpty()) {
            cfg.addDataSourceProperty(dsProp, value);
        }
    }

    private static String resolvePassword() {
        String pw = System.getenv(PASSWORD_ENV);
        if (pw == null || pw.isEmpty()) {
            throw new IllegalStateException(
                PASSWORD_ENV + " is not set; cannot connect to Snowflake.");
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
