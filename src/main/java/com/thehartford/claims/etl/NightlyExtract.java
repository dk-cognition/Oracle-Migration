package com.thehartford.claims.etl;

import com.thehartford.claims.config.DataSourceFactory;
import com.thehartford.claims.dao.DataAccessException;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * Nightly batch that unloads recently changed claims into a Snowflake external
 * stage with {@code COPY INTO @stage}. The warehouse feed picks the files up
 * from the stage (or is loaded continuously by Snowpipe), so no flat file is
 * written locally and no SFTP hop is required.
 *
 * <p>The change window uses {@code DATEADD} instead of {@code TRUNC(SYSDATE) - 1};
 * {@link #copyChangedClaimsFromStream} consumes the {@code strm_claim_changes}
 * stream (see db/snowflake/04_streams_tasks.sql) for true CDC.</p>
 */
public class NightlyExtract {

    private static final String DEFAULT_STAGE = "@claims_stage/claims";

    private final DataSource dataSource;

    public NightlyExtract() {
        this(DataSourceFactory.get());
    }

    public NightlyExtract(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    /** Unloads claims reported since midnight yesterday to {@code stagePath}. */
    public long copyChangedClaims(String stagePath) {
        String sql =
            "COPY INTO " + stagePath + "/claims_daily "
          + "FROM ("
          + "  SELECT cl.claim_id, cl.claim_number, cl.policy_id,"
          + "         TO_VARCHAR(cl.reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported,"
          + "         cl.status, cl.reserve_amount, cl.paid_amount"
          + "    FROM claim cl"
          + "   WHERE cl.reported_date >= DATEADD('day', -1, DATE_TRUNC('DAY', CURRENT_TIMESTAMP()))"
          + "   ORDER BY cl.claim_id"
          + ") "
          + "FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = '|' COMPRESSION = GZIP) "
          + "HEADER = TRUE OVERWRITE = TRUE";
        return runCopy(sql, "Nightly claim extract failed");
    }

    /**
     * CDC variant: unloads only rows captured by the claim stream. Reading the
     * stream inside a COPY advances its offset once the statement commits.
     */
    public long copyChangedClaimsFromStream(String stagePath) {
        String sql =
            "COPY INTO " + stagePath + "/claims_cdc "
          + "FROM ("
          + "  SELECT s.claim_id, s.claim_number, s.policy_id,"
          + "         TO_VARCHAR(s.reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported,"
          + "         s.status, s.reserve_amount, s.paid_amount,"
          + "         s.METADATA$ACTION AS cdc_action"
          + "    FROM strm_claim_changes s"
          + ") "
          + "FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = '|' COMPRESSION = GZIP) "
          + "HEADER = TRUE";
        return runCopy(sql, "Nightly claim CDC extract failed");
    }

    private long runCopy(String sql, String errorMessage) {
        try (Connection conn = dataSource.getConnection();
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(sql)) {
            long rows = 0;
            while (rs.next()) {
                rows += rs.getLong("rows_unloaded");
            }
            return rows;
        } catch (SQLException e) {
            throw new DataAccessException(errorMessage, e);
        }
    }

    public static void main(String[] args) {
        String stagePath = args.length > 0 ? args[0] : DEFAULT_STAGE;
        long n = new NightlyExtract().copyChangedClaims(stagePath);
        System.out.println("Unloaded " + n + " changed claim rows to " + stagePath);
    }
}
