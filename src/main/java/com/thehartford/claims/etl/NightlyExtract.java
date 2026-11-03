package com.thehartford.claims.etl;

import com.thehartford.claims.config.DataSourceFactory;
import com.thehartford.claims.dao.DataAccessException;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.regex.Pattern;

/**
 * Nightly batch that publishes recently reported claims to the downstream
 * warehouse feed.
 *
 * <p>Replaces the Oracle-era flat-file extract (JDBC rows written to a local
 * .psv, then SFTP'd): Snowflake unloads the rows itself with
 * {@code COPY INTO @stage}, so nothing is written on the application host. The
 * stage and file format are created by db/snowflake/05_etl_stage.sql.</p>
 */
public class NightlyExtract {

    static final String DEFAULT_STAGE = "@claims_extract_stage/claims";
    static final String FILE_FORMAT = "claims_psv_ff";

    // Stage paths cannot be bound as parameters, so restrict them to safe characters.
    private static final Pattern STAGE_PATH = Pattern.compile("@[A-Za-z0-9_$.~/-]+");

    private final DataSource dataSource;

    public NightlyExtract() {
        this(DataSourceFactory.get());
    }

    public NightlyExtract(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    /**
     * Unloads claims reported since midnight yesterday to
     * {@code <stage>/<runDate>/claims_*.psv}. Returns the number of rows unloaded.
     */
    public long extractChangedClaims(String stage, LocalDate runDate) {
        String sql = buildCopySql(stage, runDate);
        long rows = 0;
        try (Connection conn = dataSource.getConnection();
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(sql)) {
            while (rs.next()) {
                rows += rs.getLong("rows_unloaded");
            }
        } catch (SQLException e) {
            throw new DataAccessException("Nightly claim extract failed", e);
        }
        return rows;
    }

    static String buildCopySql(String stage, LocalDate runDate) {
        String base = stage.endsWith("/") ? stage.substring(0, stage.length() - 1) : stage;
        if (!STAGE_PATH.matcher(base).matches()) {
            throw new IllegalArgumentException("Invalid stage location: " + stage);
        }
        return "COPY INTO " + base + "/" + runDate + "/claims_ "
             + "FROM ("
             + "SELECT cl.claim_id, cl.claim_number, cl.policy_id, "
             + "       TO_VARCHAR(cl.reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported, "
             + "       cl.status, cl.reserve_amount, cl.paid_amount "
             + "  FROM claim cl "
             + " WHERE cl.reported_date >= DATEADD('day', -1, CURRENT_DATE()) "
             + " ORDER BY cl.claim_id"
             + ") "
             + "FILE_FORMAT = (FORMAT_NAME = '" + FILE_FORMAT + "') "
             + "HEADER = FALSE OVERWRITE = TRUE";
    }

    public static void main(String[] args) {
        String stage = args.length > 0 ? args[0] : DEFAULT_STAGE;
        LocalDate runDate = args.length > 1 ? LocalDate.parse(args[1]) : LocalDate.now(ZoneOffset.UTC);
        long n = new NightlyExtract().extractChangedClaims(stage, runDate);
        System.out.println("Unloaded " + n + " changed claim rows to " + stage + "/" + runDate + "/");
    }
}
