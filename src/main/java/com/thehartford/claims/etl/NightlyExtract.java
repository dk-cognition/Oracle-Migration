package com.thehartford.claims.etl;

import com.thehartford.claims.config.DataSourceFactory;
import com.thehartford.claims.dao.DataAccessException;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.LocalDate;

/**
 * Nightly batch that unloads recently changed claims to a cloud stage.
 *
 * <p>The unload is performed by Snowflake's {@code COPY INTO @stage}; the
 * result set reports the rows written by Snowflake.</p>
 */
public class NightlyExtract {

    private final DataSource dataSource;

    public NightlyExtract() {
        this(DataSourceFactory.get());
    }

    public NightlyExtract(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    public int unloadChangedClaims(String stagePathPrefix) {
        String stagePath = stagePathPrefix.endsWith("/")
            ? stagePathPrefix
            : stagePathPrefix + "/";
        String sql =
            "COPY INTO @hartford.claims_stage/" + stagePath
          + "FROM (SELECT cl.claim_id, cl.claim_number, cl.policy_id, "
          + "              TO_VARCHAR(cl.reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported, "
          + "              cl.status, cl.reserve_amount, cl.paid_amount "
          + "         FROM hartford.claim cl "
          + "        WHERE cl.reported_date >= DATEADD('day', -1, CURRENT_DATE()) "
          + "        ORDER BY cl.claim_id) "
          + "FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = '|' "
          + "                FIELD_OPTIONALLY_ENCLOSED_BY = '\"' "
          + "                COMPRESSION = NONE HEADER = TRUE)";

        int rowCount = 0;
        try (Connection conn = dataSource.getConnection();
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(sql)) {
            while (rs.next()) {
                rowCount += rs.getInt("rows_unloaded");
            }
        } catch (SQLException e) {
            throw new DataAccessException("Nightly claim extract failed", e);
        }
        return rowCount;
    }

    public static void main(String[] args) {
        String stagePath = args.length > 0
            ? args[0]
            : "claims_" + LocalDate.now();
        int n = new NightlyExtract().unloadChangedClaims(stagePath);
        System.out.println("Unloaded " + n + " changed claim rows to @" + stagePath);
    }
}
