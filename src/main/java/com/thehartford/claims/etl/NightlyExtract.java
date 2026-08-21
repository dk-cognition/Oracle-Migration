package com.thehartford.claims.etl;

import com.thehartford.claims.config.DataSourceFactory;
import com.thehartford.claims.dao.DataAccessException;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;

/**
 * Nightly claim feed for the downstream data warehouse.
 *
 * <p>The Oracle version spooled a pipe-delimited file that an external process
 * SFTP'd onward. On Snowflake the data never leaves the platform's storage path:
 * {@code COPY INTO @claims_stage} unloads straight to the cloud stage, and the
 * "changed since midnight yesterday" window ({@code TRUNC(SYSDATE) - 1}) is
 * served either by the {@code strm_claim_cdc} stream (exact CDC, the default) or
 * by a {@code DATEADD} window for backfills. Continuous inbound load is handled
 * by the Snowpipes in {@code db/snowflake/05_ingest.sql}.</p>
 */
public class NightlyExtract {

    private static final String STAGE = "@hartford.claims.claims_stage";
    private static final String FILE_FORMAT =
        "FILE_FORMAT = (FORMAT_NAME = hartford.claims.ff_claims_psv)";

    private static final String PROJECTION =
        "SELECT claim_id, claim_number, policy_id, "
      + "       TO_VARCHAR(reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported, "
      + "       status, reserve_amount, paid_amount ";

    private final DataSource dataSource;

    public NightlyExtract() {
        this(DataSourceFactory.get());
    }

    public NightlyExtract(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    /**
     * Unloads every claim change accumulated in the CDC stream to the stage and
     * advances the stream offset. Returns the number of rows unloaded.
     */
    public long unloadChangedClaims(String stagePath) {
        String copy =
            "COPY INTO " + STAGE + "/" + stagePath + " FROM ("
          + PROJECTION
          + "  FROM hartford.claims.strm_claim_cdc "
          + " WHERE METADATA$ACTION = 'INSERT' "
          + " ORDER BY claim_id) "
          + FILE_FORMAT + " HEADER = TRUE OVERWRITE = FALSE";
        return copyInto(copy, "claim CDC unload");
    }

    /**
     * Backfill variant: unloads claims reported within the last {@code days}
     * days, replacing the Oracle {@code reported_date >= TRUNC(SYSDATE) - 1}
     * predicate with {@code DATEADD} against {@code CURRENT_DATE()}.
     */
    public long unloadRecentClaims(String stagePath, int days) {
        String copy =
            "COPY INTO " + STAGE + "/" + stagePath + " FROM ("
          + PROJECTION
          + "  FROM hartford.claims.claim "
          + " WHERE reported_date >= DATEADD('day', ?, CURRENT_DATE()) "
          + " ORDER BY claim_id) "
          + FILE_FORMAT + " HEADER = TRUE OVERWRITE = TRUE";
        return copyInto(copy, "claim backfill unload", -Math.abs(days));
    }

    private long copyInto(String copy, String what, Integer... binds) {
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(copy)) {
            for (int i = 0; i < binds.length; i++) {
                ps.setInt(i + 1, binds[i]);
            }
            try (ResultSet rs = ps.executeQuery()) {
                long rows = 0;
                while (rs.next()) {
                    rows += rs.getLong("rows_unloaded");
                }
                return rows;
            }
        } catch (SQLException e) {
            throw new DataAccessException(what + " failed", e);
        }
    }

    public static void main(String[] args) {
        String stagePath = args.length > 0 ? args[0] : "claim_cdc/";
        long rows = new NightlyExtract().unloadChangedClaims(stagePath);
        System.out.println("Unloaded " + rows + " changed claim rows to " + STAGE + "/" + stagePath);
    }
}
