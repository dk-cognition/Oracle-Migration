package com.thehartford.claims.etl;

import com.thehartford.claims.config.DataSourceFactory;
import com.thehartford.claims.dao.DataAccessException;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * Nightly batch that unloads recently changed claims from Snowflake to a named
 * internal stage with {@code COPY INTO @stage}, replacing the legacy flat-file
 * extract + SFTP hop. Downstream consumers read directly from the stage (or
 * Snowpipe picks the files up for continuous load into the warehouse layer).
 *
 * <p>The Oracle {@code TRUNC(SYSDATE) - 1} window is expressed as
 * {@code DATEADD('day', -1, CURRENT_DATE())}. For true change-data-capture
 * (updates as well as inserts), see the {@code claim_changes} Stream + Task in
 * {@code db/snowflake/05_etl.sql}, which removes the window logic entirely.</p>
 */
public class NightlyExtract {

    static final String STAGE_NAME = "@hartford.claims_stage";

    private final DataSource dataSource;

    public NightlyExtract() {
        this(DataSourceFactory.get());
    }

    public NightlyExtract(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    /**
     * Unloads claims reported since midnight yesterday to the stage under the
     * given path prefix. Returns the number of rows unloaded.
     */
    public int extractChangedClaims(String stagePathPrefix) {
        String copy =
            "COPY INTO " + STAGE_NAME + "/" + stagePathPrefix + "/claims_ "
          + "  FROM ( "
          + "    SELECT cl.claim_id, cl.claim_number, cl.policy_id, "
          + "           TO_VARCHAR(cl.reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported, "
          + "           cl.status, cl.reserve_amount, cl.paid_amount "
          + "      FROM hartford.claim cl "
          + "     WHERE cl.reported_date >= DATEADD('day', -1, CURRENT_DATE()) "
          + "     ORDER BY cl.claim_id "
          + "  ) "
          + "  FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = '|' NULL_IF = ('')) "
          + "  OVERWRITE = TRUE";

        try (Connection conn = dataSource.getConnection();
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(copy)) {
            // COPY INTO <stage> returns one summary row: rows_unloaded, ...
            return rs.next() ? rs.getInt("rows_unloaded") : 0;
        } catch (SQLException e) {
            throw new DataAccessException("Nightly claim unload failed", e);
        }
    }

    public static void main(String[] args) {
        String prefix = args.length > 0 ? args[0] : "nightly";
        int n = new NightlyExtract().extractChangedClaims(prefix);
        System.out.println("Unloaded " + n + " changed claim rows to "
            + STAGE_NAME + "/" + prefix);
    }
}
