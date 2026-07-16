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
 * <p>Migrated from a flat-file flow (Oracle query -&gt; local pipe-delimited file
 * -&gt; SFTP). It now issues {@code COPY INTO @stage} directly against a Snowflake
 * stage, eliminating the flat-file hop; for continuous load, point a Snowpipe at
 * the same stage instead of running this batch. The Oracle {@code TRUNC(SYSDATE) - 1}
 * window becomes {@code DATEADD}/{@code DATE_TRUNC}; a Stream on {@code claim}
 * (CDC) is the preferred incremental alternative. See docs/MIGRATION.md.</p>
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
     * Unloads claims changed since midnight yesterday to {@code stagePath}
     * (e.g. {@code @claims_stage/claims_extract}) via COPY INTO, returning the
     * number of rows unloaded.
     */
    public long copyChangedClaimsToStage(String stagePath) {
        // TRUNC(SYSDATE) - 1 ("since midnight yesterday") -> DATEADD/DATE_TRUNC.
        // For CDC, replace the WHERE window with a Stream on the claim table.
        String copy =
            "COPY INTO " + stagePath + " "
          + "FROM ("
          + "  SELECT cl.claim_id, cl.claim_number, cl.policy_id, "
          + "         TO_VARCHAR(cl.reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported, "
          + "         cl.status, cl.reserve_amount, cl.paid_amount "
          + "    FROM claim cl "
          + "   WHERE cl.reported_date >= DATEADD('day', -1, DATE_TRUNC('DAY', CURRENT_TIMESTAMP())) "
          + "   ORDER BY cl.claim_id"
          + ") "
          + "FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = '|' COMPRESSION = NONE) "
          + "HEADER = FALSE OVERWRITE = TRUE";

        try (Connection conn = dataSource.getConnection();
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(copy)) {

            // COPY INTO <location> returns one row per data file with rows_unloaded.
            long rowsUnloaded = 0;
            while (rs.next()) {
                rowsUnloaded += rs.getLong("rows_unloaded");
            }
            return rowsUnloaded;
        } catch (SQLException e) {
            throw new DataAccessException("Nightly claim COPY INTO failed", e);
        }
    }

    public static void main(String[] args) {
        String stage = args.length > 0 ? args[0] : "@claims_stage/claims_extract";
        long n = new NightlyExtract().copyChangedClaimsToStage(stage);
        System.out.println("Unloaded " + n + " changed claim rows to " + stage);
    }
}
