package com.thehartford.claims.etl;

import com.thehartford.claims.config.DataSourceFactory;
import com.thehartford.claims.dao.DataAccessException;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * Nightly batch that publishes recently changed claims for the downstream feed.
 *
 * <p>Replaces the legacy Oracle pattern (JDBC fetch, pipe-delimited flat file,
 * SFTP hop) with a Snowflake-native {@code COPY INTO @stage} unload straight to
 * the cloud stage. Continuous inbound loading is handled by Snowpipe (see
 * db/snowflake/05_stage_and_pipe.sql); this class covers the outbound nightly
 * feed of changed claims.</p>
 */
public class NightlyExtract {

    private final DataSource dataSource;

    public NightlyExtract() {
        this(DataSourceFactory.get());
    }

    public NightlyExtract(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    /**
     * Unloads claims reported since midnight yesterday directly to the stage.
     *
     * @param stagePath path under the stage, e.g. {@code @hartford.claims_stage/outbound/claims_}
     * @return the number of rows unloaded
     */
    public int extractChangedClaims(String stagePath) {
        String sql =
            "COPY INTO " + stagePath
          + "  FROM ("
          + "    SELECT cl.claim_id, cl.claim_number, cl.policy_id, "
          + "           TO_VARCHAR(cl.reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported, "
          + "           cl.status, cl.reserve_amount, cl.paid_amount "
          + "      FROM hartford.claim cl "
          + "     WHERE cl.reported_date >= DATEADD('day', -1, CURRENT_DATE()) "
          + "     ORDER BY cl.claim_id"
          + "  ) "
          + "  FILE_FORMAT = (FORMAT_NAME = 'hartford.ff_psv') "
          + "  OVERWRITE = TRUE";

        try (Connection conn = dataSource.getConnection();
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(sql)) {
            // COPY INTO <stage> returns one row with rows_unloaded.
            return rs.next() ? rs.getInt("rows_unloaded") : 0;
        } catch (SQLException e) {
            throw new DataAccessException("Nightly claim extract failed", e);
        }
    }

    public static void main(String[] args) {
        String stagePath = args.length > 0 ? args[0] : "@hartford.claims_stage/outbound/claims_";
        int n = new NightlyExtract().extractChangedClaims(stagePath);
        System.out.println("Unloaded " + n + " changed claim rows to " + stagePath);
    }
}
