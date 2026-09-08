package com.thehartford.claims.etl;

import com.thehartford.claims.config.DataSourceFactory;
import com.thehartford.claims.config.SqlLibrary;
import com.thehartford.claims.dao.DataAccessException;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.LocalDate;
import java.time.format.DateTimeFormatter;

/**
 * Nightly batch that unloads recently changed claims for the downstream data
 * warehouse feed.
 *
 * <p>Runs the {@code changed_claims_export} {@code COPY INTO @claims_export}
 * statement from {@code sql/reports.sql}, so the data goes straight from
 * Snowflake to the cloud stage. There is no local flat file and no SFTP hop;
 * inbound payment files are handled continuously by Snowpipe
 * ({@code db/snowflake/05_stage_pipe.sql}).</p>
 */
public class NightlyExtract {

    static final String RUN_DATE_TOKEN = "{{run_date}}";
    private static final DateTimeFormatter RUN_DATE = DateTimeFormatter.BASIC_ISO_DATE;

    private final DataSource dataSource;
    private final SqlLibrary sql;

    public NightlyExtract() {
        this(DataSourceFactory.get());
    }

    public NightlyExtract(DataSource dataSource) {
        this.dataSource = dataSource;
        this.sql = SqlLibrary.fromResource("/sql/reports.sql");
    }

    /**
     * Unloads claims reported since midnight yesterday to
     * {@code @claims_export/claims/<yyyyMMdd>/} and returns the number of rows
     * unloaded (the {@code rows_unloaded} column of the COPY INTO result).
     */
    public long extractChangedClaims(LocalDate runDate) {
        String statement = buildStatement(runDate);
        try (Connection conn = dataSource.getConnection();
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(statement)) {
            return rs.next() ? rs.getLong("rows_unloaded") : 0L;
        } catch (SQLException e) {
            throw new DataAccessException("Nightly claim unload failed", e);
        }
    }

    String buildStatement(LocalDate runDate) {
        return sql.get("changed_claims_export").replace(RUN_DATE_TOKEN, RUN_DATE.format(runDate));
    }

    public static void main(String[] args) {
        LocalDate runDate = args.length > 0 ? LocalDate.parse(args[0]) : LocalDate.now();
        long n = new NightlyExtract().extractChangedClaims(runDate);
        System.out.println("Unloaded " + n + " changed claim rows to @claims_export/claims/"
            + RUN_DATE.format(runDate) + "/");
    }
}
