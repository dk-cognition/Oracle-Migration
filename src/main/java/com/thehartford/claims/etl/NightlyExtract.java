package com.thehartford.claims.etl;

import com.thehartford.claims.config.DataSourceFactory;
import com.thehartford.claims.dao.DataAccessException;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * Nightly batch that publishes recently changed claims to the downstream
 * warehouse feed.
 *
 * <p>Runs {@code COPY INTO @claims_stage} directly inside Snowflake, unloading
 * from the {@code str_claim_changes} Stream (see
 * {@code db/snowflake/04_streams_tasks.sql}). The Stream tracks exactly the
 * rows changed since the last consumption, replacing the old
 * {@code TRUNC(SYSDATE) - 1} date-window predicate, and the stage replaces the
 * flat-file + SFTP hop. Inbound loads are handled continuously by Snowpipe
 * ({@code pipe_claims_load}).</p>
 */
public class NightlyExtract {

    private final DataSource dataSource;

    public NightlyExtract() {
        this(DataSourceFactory.get());
    }

    public NightlyExtract(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    public int extractChangedClaims(String stagePathSuffix) {
        String copy =
            "COPY INTO @claims_stage/outbound/claims_extract_" + stagePathSuffix
          + "  FROM ("
          + "    SELECT claim_id, claim_number, policy_id, "
          + "           TO_VARCHAR(reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported, "
          + "           status, reserve_amount, paid_amount "
          + "      FROM str_claim_changes "
          + "     WHERE METADATA$ACTION = 'INSERT' "
          + "     ORDER BY claim_id "
          + "  ) "
          + " FILE_FORMAT = (FORMAT_NAME = ff_claims_psv) "
          + " OVERWRITE = FALSE";

        try (Connection conn = dataSource.getConnection();
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(copy)) {
            // COPY INTO <stage> returns one row with rows_unloaded.
            return rs.next() ? rs.getInt("rows_unloaded") : 0;
        } catch (SQLException e) {
            throw new DataAccessException("Nightly claim extract failed", e);
        }
    }

    public static void main(String[] args) {
        String suffix = args.length > 0 ? args[0] : String.valueOf(System.currentTimeMillis());
        int n = new NightlyExtract().extractChangedClaims(suffix);
        System.out.println("Unloaded " + n + " changed claim rows to @claims_stage/outbound/");
    }
}
