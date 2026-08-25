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
 * <p>Targets Snowflake: the JDBC URL is a {@code jdbc:snowflake://} account URL
 * and warehouse/database/schema/role are passed as connection properties.</p>
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

        addIfPresent(cfg, props, "db.warehouse", "warehouse");
        addIfPresent(cfg, props, "db.database", "db");
        addIfPresent(cfg, props, "db.schema", "schema");
        addIfPresent(cfg, props, "db.role", "role");

        String initSql = props.getProperty("db.pool.connectionInitSql");
        if (initSql != null) {
            cfg.setConnectionInitSql(initSql);
        }

        return new HikariDataSource(cfg);
    }

    private static void addIfPresent(HikariConfig cfg, Properties props,
                                     String propKey, String dsKey) {
        String value = props.getProperty(propKey);
        if (value != null && !value.isEmpty()) {
            cfg.addDataSourceProperty(dsKey, value);
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
