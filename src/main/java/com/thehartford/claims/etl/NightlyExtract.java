package com.thehartford.claims.etl;

import com.thehartford.claims.config.DataSourceFactory;
import com.thehartford.claims.dao.DataAccessException;

import javax.sql.DataSource;
import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * Nightly batch that extracts recently changed claims to a pipe-delimited file
 * for the downstream data warehouse feed.
 *
 * <p>MIGRATION NOTE: today this reads from Oracle and writes a flat file that an
 * external process SFTPs to the warehouse. The Snowflake target replaces this
 * whole pattern with {@code COPY INTO @stage} (or Snowpipe) directly against a
 * cloud stage, eliminating the flat-file hop. This class also uses Oracle
 * {@code TRUNC(SYSDATE)} and {@code TO_CHAR} which do not port verbatim.</p>
 */
public class NightlyExtract {

    private final DataSource dataSource;

    public NightlyExtract() {
        this(DataSourceFactory.get());
    }

    public NightlyExtract(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    public int extractChangedClaims(Path outputFile) {
        // Oracle-specific: TRUNC(SYSDATE) - 1 => "since midnight yesterday".
        String sql =
            "SELECT cl.claim_id, cl.claim_number, cl.policy_id, "
          + "       TO_CHAR(cl.reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported, "
          + "       cl.status, cl.reserve_amount, cl.paid_amount "
          + "  FROM hartford.claim cl "
          + " WHERE cl.reported_date >= TRUNC(SYSDATE) - 1 "
          + " ORDER BY cl.claim_id";

        int rowCount = 0;
        try (Connection conn = dataSource.getConnection();
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(sql);
             BufferedWriter writer = Files.newBufferedWriter(outputFile)) {

            ResultSetMetaData md = rs.getMetaData();
            int cols = md.getColumnCount();

            while (rs.next()) {
                StringBuilder line = new StringBuilder();
                for (int i = 1; i <= cols; i++) {
                    if (i > 1) {
                        line.append('|');
                    }
                    String v = rs.getString(i);
                    line.append(v == null ? "" : v);
                }
                writer.write(line.toString());
                writer.newLine();
                rowCount++;
            }
        } catch (SQLException e) {
            throw new DataAccessException("Nightly claim extract failed", e);
        } catch (IOException e) {
            throw new RuntimeException("Failed writing extract file " + outputFile, e);
        }
        return rowCount;
    }

    public static void main(String[] args) {
        Path out = Path.of(args.length > 0 ? args[0] : "claims_extract.psv");
        int n = new NightlyExtract().extractChangedClaims(out);
        System.out.println("Wrote " + n + " changed claim rows to " + out);
    }
}
