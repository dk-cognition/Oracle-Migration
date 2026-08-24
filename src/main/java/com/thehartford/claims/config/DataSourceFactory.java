package com.thehartford.claims.config;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

import javax.sql.DataSource;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Properties;

/**
 * Builds the application {@link DataSource} from application.properties.
 *
 * <p>The Snowflake account URL, warehouse, database, schema, and role are
 * configured in application.properties. See docs/MIGRATION.md.</p>
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
        cfg.setJdbcUrl(buildJdbcUrl(props));
        cfg.setUsername(props.getProperty("db.username"));
        cfg.setPassword(resolvePassword());
        cfg.setMaximumPoolSize(Integer.parseInt(props.getProperty("db.pool.maxSize", "10")));

        String initSql = props.getProperty("db.pool.connectionInitSql");
        if (initSql != null) {
            cfg.setConnectionInitSql(initSql);
        }

        return new HikariDataSource(cfg);
    }

    private static String buildJdbcUrl(Properties props) {
        String base = props.getProperty("db.url");
        List<String> parameters = new ArrayList<>();
        addParameter(parameters, "warehouse", props.getProperty("db.warehouse"));
        addParameter(parameters, "db", props.getProperty("db.database"));
        addParameter(parameters, "schema", props.getProperty("db.schema"));
        addParameter(parameters, "role", props.getProperty("db.role"));
        if (parameters.isEmpty()) {
            return base;
        }
        return base + (base.contains("?") ? "&" : "?") + String.join("&", parameters);
    }

    private static void addParameter(List<String> parameters, String name, String value) {
        if (value != null && !value.isEmpty()) {
            parameters.add(name + "=" + value);
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
