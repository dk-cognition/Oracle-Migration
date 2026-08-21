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
 * <p>Connects to Snowflake: the account URL carries the warehouse, database,
 * schema, and role, so there is no TNS descriptor and no connection init SQL.</p>
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
        cfg.setJdbcUrl(jdbcUrl(props));
        cfg.setUsername(props.getProperty("db.username"));
        cfg.setPassword(resolvePassword());
        cfg.setMaximumPoolSize(Integer.parseInt(props.getProperty("db.pool.maxSize", "10")));

        return new HikariDataSource(cfg);
    }

    /** Appends the Snowflake session settings to the account URL as query parameters. */
    static String jdbcUrl(Properties props) {
        StringBuilder url = new StringBuilder(require(props, "db.url"));
        char separator = url.indexOf("?") >= 0 ? '&' : '?';
        for (String key : new String[] {"db.warehouse", "db.database", "db.schema", "db.role"}) {
            String value = props.getProperty(key);
            if (value != null && !value.isEmpty()) {
                url.append(separator)
                   .append(key.substring("db.".length()))
                   .append('=')
                   .append(value);
                separator = '&';
            }
        }
        return url.toString();
    }

    private static String require(Properties props, String key) {
        String value = props.getProperty(key);
        if (value == null || value.isEmpty()) {
            throw new IllegalStateException("Missing required property: " + key);
        }
        return value;
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
