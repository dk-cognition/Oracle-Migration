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
import java.util.Properties;
import java.util.regex.Pattern;

/**
 * Nightly batch that unloads claims reported since midnight yesterday to a
 * Snowflake stage for the downstream feed.
 *
 * <p>Replaces the old Oracle flat-file + SFTP hop: a single
 * {@code COPY INTO @stage/claims/<run-date>/} runs inside Snowflake and writes
 * pipe-delimited files straight to the stage (see db/snowflake/05_etl_stage.sql).
 * Re-running for the same date overwrites that date's files.</p>
 */
public class NightlyExtract {

    private static final Pattern STAGE = Pattern.compile("@[A-Za-z0-9_$.~/-]+");
    private static final Pattern IDENTIFIER = Pattern.compile("[A-Za-z0-9_$.]+");

    static final String CHANGED_CLAIMS_QUERY =
        "SELECT cl.claim_id, cl.claim_number, cl.policy_id, "
      + "       TO_VARCHAR(cl.reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported, "
      + "       cl.status, cl.reserve_amount, cl.paid_amount "
      + "  FROM claim cl "
      + " WHERE cl.reported_date >= DATEADD('day', -1, CURRENT_DATE()) "
      + " ORDER BY cl.claim_id";

    private final DataSource dataSource;
    private final String stage;
    private final String fileFormat;

    public NightlyExtract() {
        this(DataSourceFactory.get(), DataSourceFactory.load("/application.properties"));
    }

    private NightlyExtract(DataSource dataSource, Properties props) {
        this(dataSource,
             props.getProperty("etl.stage", "@claims_extract_stage"),
             props.getProperty("etl.fileFormat", "psv_format"));
    }

    public NightlyExtract(DataSource dataSource, String stage, String fileFormat) {
        this.dataSource = dataSource;
        this.stage = stage;
        this.fileFormat = fileFormat;
    }

    /** Unloads changed claims for {@code runDate} and returns the number of rows unloaded. */
    public long extractChangedClaims(LocalDate runDate) {
        String sql = buildCopySql(stage, fileFormat, runDate);
        long rowsUnloaded = 0;
        try (Connection conn = dataSource.getConnection();
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(sql)) {
            while (rs.next()) {
                rowsUnloaded += rs.getLong("rows_unloaded");
            }
        } catch (SQLException e) {
            throw new DataAccessException("Nightly claim extract failed", e);
        }
        return rowsUnloaded;
    }

    /** Builds the {@code COPY INTO @stage} unload statement for one run date. */
    static String buildCopySql(String stage, String fileFormat, LocalDate runDate) {
        if (stage == null || !STAGE.matcher(stage).matches()) {
            throw new IllegalArgumentException("Invalid stage reference: " + stage);
        }
        if (fileFormat == null || !IDENTIFIER.matcher(fileFormat).matches()) {
            throw new IllegalArgumentException("Invalid file format name: " + fileFormat);
        }
        String base = stage.endsWith("/") ? stage.substring(0, stage.length() - 1) : stage;
        return "COPY INTO " + base + "/claims/" + runDate + "/claims_changed_"
            + " FROM (" + CHANGED_CLAIMS_QUERY + ")"
            + " FILE_FORMAT = (FORMAT_NAME = '" + fileFormat + "')"
            + " HEADER = FALSE"
            + " OVERWRITE = TRUE";
    }

    public static void main(String[] args) {
        LocalDate runDate = args.length > 0 ? LocalDate.parse(args[0]) : LocalDate.now(ZoneOffset.UTC);
        long n = new NightlyExtract().extractChangedClaims(runDate);
        System.out.println("Unloaded " + n + " changed claim rows for " + runDate);
    }
}
