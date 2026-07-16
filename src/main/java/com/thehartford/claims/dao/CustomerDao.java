package com.thehartford.claims.dao;

import com.thehartford.claims.config.DataSourceFactory;
import com.thehartford.claims.config.SqlLibrary;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * Data access for customers.
 *
 * <p>Migrated to Snowflake: {@code customer_id} is an AUTOINCREMENT column (the
 * Oracle sequence + {@code trg_customer_biu} trigger are gone). Snowflake has no
 * {@code getGeneratedKeys()}/ROWID and no per-session {@code CURRVAL}, so the id
 * is read back with a follow-up query. See docs/MIGRATION.md.</p>
 */
public class CustomerDao {

    private final DataSource dataSource;
    private final SqlLibrary sql;

    public CustomerDao() {
        this(DataSourceFactory.get());
    }

    public CustomerDao(DataSource dataSource) {
        this.dataSource = dataSource;
        this.sql = SqlLibrary.fromResource("/sql/reports.sql");
    }

    /** Inserts a customer; the AUTOINCREMENT customer_id is read back afterwards. */
    public long insert(String firstName, String lastName, String email) {
        String insert =
            "INSERT INTO hartford.customer (first_name, last_name, email) VALUES (?, ?, ?)";
        // Snowflake has no getGeneratedKeys()/ROWID; re-query the assigned id.
        // (MAX is best-effort; a serialized writer or dedicated sequence is safer
        // under concurrency.)
        String readBack = "SELECT MAX(customer_id) FROM hartford.customer";
        try (Connection conn = dataSource.getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(insert)) {
                ps.setString(1, firstName);
                ps.setString(2, lastName);
                ps.setString(3, email);
                ps.executeUpdate();
            }
            try (Statement st = conn.createStatement();
                 ResultSet rs = st.executeQuery(readBack)) {
                if (rs.next()) {
                    return rs.getLong(1);
                }
            }
            throw new DataAccessException("No id read back for customer insert", null);
        } catch (SQLException e) {
            throw new DataAccessException("insert customer failed", e);
        }
    }

    /** Upsert via the Snowflake MERGE (USING (SELECT ...) src) in reports.sql. */
    public void upsert(long customerId, String firstName, String lastName, String email) {
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql.get("customer_upsert"))) {
            ps.setLong(1, customerId);
            ps.setString(2, firstName);
            ps.setString(3, lastName);
            ps.setString(4, email);
            ps.executeUpdate();
        } catch (SQLException e) {
            throw new DataAccessException("upsert customer " + customerId + " failed", e);
        }
    }

    /**
     * Best-effort next customer id. Snowflake AUTOINCREMENT exposes no gap-free,
     * authoritative peek (no DUAL, no sequence CURRVAL here), so this returns
     * MAX(customer_id) + 1 as an estimate only.
     */
    public long peekNextId() {
        String q = "SELECT COALESCE(MAX(customer_id), 99999) + 1 FROM hartford.customer";
        try (Connection conn = dataSource.getConnection();
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(q)) {
            return rs.next() ? rs.getLong(1) : -1L;
        } catch (SQLException e) {
            throw new DataAccessException("peekNextId failed", e);
        }
    }
}
