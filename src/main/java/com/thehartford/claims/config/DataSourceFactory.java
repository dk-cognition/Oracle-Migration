package com.thehartford.claims.config;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

import javax.sql.DataSource;
import java.io.IOException;
import java.io.InputStream;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Properties;

/**
 * Builds the application {@link DataSource} from application.properties, pointed
 * at Snowflake.
 *
 * <p>The JDBC URL is {@code jdbc:snowflake://<account>.snowflakecomputing.com/}
 * with warehouse, database, schema and role passed as URL parameters, so every
 * pooled connection lands in the right context without init SQL. Credentials
 * come from the environment: key-pair auth via {@code SNOWFLAKE_PRIVATE_KEY_FILE}
 * (preferred) or password auth via {@code SNOWFLAKE_APP_PASSWORD}.</p>
 */
public final class DataSourceFactory {

    static final String ENV_PRIVATE_KEY_FILE = "SNOWFLAKE_PRIVATE_KEY_FILE";
    static final String ENV_PRIVATE_KEY_PWD = "SNOWFLAKE_PRIVATE_KEY_PWD";
    static final String ENV_PASSWORD = "SNOWFLAKE_APP_PASSWORD";

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
        cfg.setMaximumPoolSize(Integer.parseInt(props.getProperty("db.pool.maxSize", "10")));
        applyCredentials(cfg);
        return new HikariDataSource(cfg);
    }

    /**
     * Returns {@code db.url} if set, otherwise builds
     * {@code jdbc:snowflake://<db.account>.snowflakecomputing.com/?warehouse=..&db=..&schema=..&role=..}.
     */
    public static String buildJdbcUrl(Properties props) {
        String explicit = props.getProperty("db.url");
        if (explicit != null && !explicit.isBlank()) {
            return explicit.trim();
        }
        String account = props.getProperty("db.account");
        if (account == null || account.isBlank()) {
            throw new IllegalStateException("Either db.url or db.account must be configured.");
        }

        Map<String, String> params = new LinkedHashMap<>();
        params.put("warehouse", props.getProperty("db.warehouse"));
        params.put("db", props.getProperty("db.database"));
        params.put("schema", props.getProperty("db.schema"));
        params.put("role", props.getProperty("db.role"));

        StringBuilder url = new StringBuilder("jdbc:snowflake://")
            .append(account.trim())
            .append(".snowflakecomputing.com/");
        char sep = '?';
        for (Map.Entry<String, String> e : params.entrySet()) {
            String value = e.getValue();
            if (value != null && !value.isBlank()) {
                url.append(sep).append(e.getKey()).append('=')
                   .append(URLEncoder.encode(value.trim(), StandardCharsets.UTF_8));
                sep = '&';
            }
        }
        return url.toString();
    }

    private static void applyCredentials(HikariConfig cfg) {
        String keyFile = System.getenv(ENV_PRIVATE_KEY_FILE);
        if (keyFile != null && !keyFile.isEmpty()) {
            cfg.addDataSourceProperty("private_key_file", keyFile);
            String keyPwd = System.getenv(ENV_PRIVATE_KEY_PWD);
            if (keyPwd != null && !keyPwd.isEmpty()) {
                cfg.addDataSourceProperty("private_key_file_pwd", keyPwd);
            }
            return;
        }
        String pw = System.getenv(ENV_PASSWORD);
        if (pw == null || pw.isEmpty()) {
            throw new IllegalStateException(
                "Neither " + ENV_PRIVATE_KEY_FILE + " nor " + ENV_PASSWORD
                    + " is set; cannot connect to Snowflake.");
        }
        cfg.setPassword(pw);
    }

    public static Properties load(String resource) {
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
