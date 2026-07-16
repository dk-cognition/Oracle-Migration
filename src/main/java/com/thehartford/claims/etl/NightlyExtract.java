package com.thehartford.claims.etl;

import com.thehartford.claims.config.DataSourceFactory;
import com.thehartford.claims.dao.DataAccessException;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * Nightly batch that unloads recently changed claims to a Snowflake stage for
 * the downstream data warehouse feed.
 *
 * <p>Migrated to Snowflake: instead of streaming rows into a local pipe-delimited
 * flat file (later SFTP'd to the warehouse), this issues a single
 * {@code COPY INTO @stage} that unloads straight to a cloud stage, eliminating
 * the flat-file hop. Snowpipe can then continuously ingest from that stage.
 * Oracle {@code TRUNC(SYSDATE) - 1} becomes
 * {@code DATEADD('day', -1, DATE_TRUNC('DAY', CURRENT_TIMESTAMP()))} and
 * {@code TO_CHAR} becomes {@code TO_VARCHAR}. See docs/MIGRATION.md section 8.</p>
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
     * Unloads claims changed "since midnight yesterday" to the given stage path
     * (e.g. {@code @claims_stage/claims_extract}) as pipe-delimited CSV and
     * returns the number of rows unloaded.
     */
    public int extractChangedClaims(String stagePath) {
        String copy =
            "COPY INTO " + stagePath + " "
          + "FROM ("
          + "  SELECT cl.claim_id, cl.claim_number, cl.policy_id, "
          + "         TO_VARCHAR(cl.reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported, "
          + "         cl.status, cl.reserve_amount, cl.paid_amount "
          + "    FROM hartford.claim cl "
          + "   WHERE cl.reported_date >= DATEADD('day', -1, DATE_TRUNC('DAY', CURRENT_TIMESTAMP())) "
          + "   ORDER BY cl.claim_id"
          + ") "
          + "FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = '|' NULL_IF = ('') EMPTY_FIELD_AS_NULL = FALSE) "
          + "HEADER = TRUE OVERWRITE = TRUE SINGLE = TRUE";

        try (Connection conn = dataSource.getConnection();
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(copy)) {
            // COPY INTO <location> returns a summary row incl. rows_unloaded.
            return rs.next() ? rs.getInt("rows_unloaded") : 0;
        } catch (SQLException e) {
            throw new DataAccessException("Nightly claim extract failed", e);
        }
    }

    public static void main(String[] args) {
        String stagePath = args.length > 0 ? args[0] : "@claims_stage/claims_extract";
        int n = new NightlyExtract().extractChangedClaims(stagePath);
        System.out.println("Unloaded " + n + " changed claim rows to " + stagePath);
    }
}
