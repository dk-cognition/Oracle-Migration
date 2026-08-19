package com.thehartford.claims.etl;

import com.thehartford.claims.config.DataSourceFactory;
import com.thehartford.claims.dao.DataAccessException;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * Nightly batch that hands recently changed claims to the downstream warehouse.
 *
 * <p>The Oracle version selected a {@code TRUNC(SYSDATE) - 1} window and wrote a
 * pipe-delimited file for an external SFTP hop. On Snowflake the rows never leave
 * the platform: {@link #unloadChangedClaims} runs {@code COPY INTO @stage}
 * against the CDC stream drained by {@code tsk_claim_cdc} (see
 * {@code db/snowflake/04_streams_tasks.sql}), and the warehouse loads from the
 * same stage via Snowpipe. {@link #unloadBackfillWindow} keeps a date-window
 * unload available for reloads.</p>
 */
public class NightlyExtract {

    private static final String DEFAULT_STAGE = "@hartford.claims.claims_stage/claims";

    private final DataSource dataSource;

    public NightlyExtract() {
        this(DataSourceFactory.get());
    }

    public NightlyExtract(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    /**
     * Unloads the claim changes captured since the last run to the cloud stage
     * and clears the feed. Returns the number of rows written.
     */
    public int unloadChangedClaims(String stagePath) {
        String copy =
            "COPY INTO " + stagePath + "/claims_cdc_ "
          + "FROM (SELECT claim_id, claim_number, policy_id, reported_date, status, "
          + "             reserve_amount, paid_amount, change_action "
          + "        FROM hartford.claims.claim_change_feed "
          + "       ORDER BY claim_id) "
          + "FILE_FORMAT = (TYPE = CSV COMPRESSION = GZIP FIELD_DELIMITER = '|' "
          + "               NULL_IF = ('') EMPTY_FIELD_AS_NULL = FALSE) "
          + "HEADER = TRUE OVERWRITE = FALSE";

        try (Connection conn = dataSource.getConnection()) {
            int rows = copyInto(conn, copy);
            try (Statement st = conn.createStatement()) {
                st.executeUpdate("DELETE FROM hartford.claims.claim_change_feed");
            }
            return rows;
        } catch (SQLException e) {
            throw new DataAccessException("Nightly claim unload failed", e);
        }
    }

    /**
     * Reload path: unloads a trailing window of claims (the equivalent of the
     * former {@code TRUNC(SYSDATE) - 1} scan, expressed with DATEADD).
     */
    public int unloadBackfillWindow(String stagePath, int days) {
        String copy =
            "COPY INTO " + stagePath + "/claims_backfill_ "
          + "FROM (SELECT claim_id, claim_number, policy_id, reported_date, status, "
          + "             reserve_amount, paid_amount "
          + "        FROM hartford.claims.claim "
          + "       WHERE reported_date >= "
          + "             DATEADD('day', ?, DATE_TRUNC('DAY', CURRENT_TIMESTAMP())) "
          + "       ORDER BY claim_id) "
          + "FILE_FORMAT = (TYPE = CSV COMPRESSION = GZIP FIELD_DELIMITER = '|') "
          + "HEADER = TRUE OVERWRITE = TRUE";

        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(copy)) {
            ps.setInt(1, -Math.abs(days));
            try (ResultSet rs = ps.executeQuery()) {
                return rowsUnloaded(rs);
            }
        } catch (SQLException e) {
            throw new DataAccessException("Claim backfill unload failed", e);
        }
    }

    private int copyInto(Connection conn, String copy) throws SQLException {
        try (Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(copy)) {
            return rowsUnloaded(rs);
        }
    }

    /** COPY INTO &lt;location&gt; reports rows_unloaded in its result set. */
    private int rowsUnloaded(ResultSet rs) throws SQLException {
        int rows = 0;
        while (rs.next()) {
            rows += rs.getInt("rows_unloaded");
        }
        return rows;
    }

    public static void main(String[] args) {
        String stage = args.length > 0 ? args[0] : DEFAULT_STAGE;
        int n = new NightlyExtract().unloadChangedClaims(stage);
        System.out.println("Unloaded " + n + " changed claim rows to " + stage);
    }
}
