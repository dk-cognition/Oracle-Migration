package com.thehartford.claims.etl;

import com.thehartford.claims.config.DataSourceFactory;
import com.thehartford.claims.dao.DataAccessException;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;

/**
 * Nightly batch that publishes recently changed claims to the warehouse feed.
 *
 * <p>Migrated to Snowflake: instead of spooling a pipe-delimited flat file for an
 * external SFTP hop, the changed rows are unloaded with {@code COPY INTO @stage}
 * straight into the claims stage, where Snowpipe (see
 * {@code scripts/export_to_snowflake_stage.sh} for the stage and pipe
 * definitions) picks them up. {@code TRUNC(SYSDATE) - 1} becomes
 * {@code DATEADD('day', -1, CURRENT_DATE())}. See docs/MIGRATION.md.</p>
 */
public class NightlyExtract {

    /** Cloud stage the warehouse feed reads from. */
    public static final String DEFAULT_STAGE = "@hartford.claims.claims_stage";

    private final DataSource dataSource;

    public NightlyExtract() {
        this(DataSourceFactory.get());
    }

    public NightlyExtract(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    /**
     * Unloads claims reported since midnight yesterday to {@code stagePath} as
     * gzipped Parquet and returns the number of rows written.
     *
     * @param stagePath stage location, e.g. {@code @hartford.claims.claims_stage/claims/}
     */
    public long unloadChangedClaims(String stagePath) {
        String copy =
            "COPY INTO " + stagePath + " FROM ("
          + "SELECT cl.claim_id, cl.claim_number, cl.policy_id, "
          + "       TO_VARCHAR(cl.reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported, "
          + "       cl.status, cl.reserve_amount, cl.paid_amount "
          + "  FROM hartford.claims.claim cl "
          + " WHERE cl.reported_date >= DATEADD('day', -1, CURRENT_DATE()) "
          + " ORDER BY cl.claim_id) "
          + "FILE_FORMAT = (TYPE = PARQUET COMPRESSION = SNAPPY) "
          + "OVERWRITE = TRUE";

        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(copy);
             ResultSet rs = ps.executeQuery()) {
            // COPY INTO <location> reports rows_unloaded / input_bytes / output_bytes.
            return rs.next() ? rs.getLong("rows_unloaded") : 0L;
        } catch (SQLException e) {
            throw new DataAccessException("Nightly claim unload to " + stagePath + " failed", e);
        }
    }

    public static void main(String[] args) {
        String stagePath = args.length > 0 ? args[0] : DEFAULT_STAGE + "/claims/";
        long n = new NightlyExtract().unloadChangedClaims(stagePath);
        System.out.println("Unloaded " + n + " changed claim rows to " + stagePath);
    }
}
