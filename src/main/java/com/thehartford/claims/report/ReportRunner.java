package com.thehartford.claims.report;

import com.thehartford.claims.config.DataSourceFactory;
import com.thehartford.claims.config.SqlLibrary;
import com.thehartford.claims.dao.DataAccessException;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * Executes the named reporting queries from {@code sql/reports.sql} and prints
 * them as a simple tab-delimited grid.
 *
 * <p>The queries are Snowflake dialect (recursive CTEs, QUALIFY, CASE, IFF,
 * DATEADD); see docs/MIGRATION.md for the mapping from their Oracle originals.</p>
 */
public class ReportRunner {

    private final DataSource dataSource;
    private final SqlLibrary sql;

    public ReportRunner() {
        this(DataSourceFactory.get());
    }

    public ReportRunner(DataSource dataSource) {
        this.dataSource = dataSource;
        this.sql = SqlLibrary.fromResource("/sql/reports.sql");
    }

    public void printAgentOrgChart() {
        runAndPrint("agent_org_chart");
    }

    public void printMonthlyPremium() {
        runAndPrint("monthly_premium");
    }

    public void printStaleOpenClaims() {
        runAndPrint("stale_open_claims");
    }

    public void printHighRiskCustomers() {
        runAndPrint("high_risk_customers");
    }

    private void runAndPrint(String name) {
        String statement = sql.get(name);
        System.out.println("=== " + name + " ===");
        try (Connection conn = dataSource.getConnection();
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(statement)) {

            ResultSetMetaData md = rs.getMetaData();
            int cols = md.getColumnCount();
            StringBuilder header = new StringBuilder();
            for (int i = 1; i <= cols; i++) {
                if (i > 1) {
                    header.append('\t');
                }
                header.append(md.getColumnLabel(i));
            }
            System.out.println(header);

            while (rs.next()) {
                StringBuilder row = new StringBuilder();
                for (int i = 1; i <= cols; i++) {
                    if (i > 1) {
                        row.append('\t');
                    }
                    row.append(rs.getString(i));
                }
                System.out.println(row);
            }
        } catch (SQLException e) {
            throw new DataAccessException("Report '" + name + "' failed", e);
        }
    }

    public static void main(String[] args) {
        ReportRunner runner = new ReportRunner();
        runner.printAgentOrgChart();
        runner.printMonthlyPremium();
        runner.printStaleOpenClaims();
        runner.printHighRiskCustomers();
    }
}
