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
 * <p>MIGRATION NOTE: this factory is hard-wired to the Oracle thin driver and a
 * TNS descriptor. Migrating to Snowflake means swapping the driver, dropping the
 * {@code oracle.net.tns_admin} system property, and using a Snowflake account URL
 * plus warehouse/role. See docs/MIGRATION.md.</p>
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

        // Oracle TNS resolution depends on this JVM system property.
        String tnsAdmin = props.getProperty("db.tns.admin");
        if (tnsAdmin != null) {
            System.setProperty("oracle.net.tns_admin", tnsAdmin);
        }

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

        // Oracle-specific tuning that has no Snowflake equivalent.
        cfg.addDataSourceProperty("oracle.jdbc.implicitStatementCacheSize", "50");
        cfg.addDataSourceProperty("defaultRowPrefetch", "500");

        return new HikariDataSource(cfg);
    }

    private static String resolvePassword() {
        String pw = System.getenv("ORACLE_APP_PASSWORD");
        if (pw == null || pw.isEmpty()) {
            throw new IllegalStateException(
                "ORACLE_APP_PASSWORD is not set; cannot connect to Oracle.");
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
