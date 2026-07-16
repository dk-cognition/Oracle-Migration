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
 * <p>Migrated to Snowflake. {@code customer_id} is now an AUTOINCREMENT column
 * (was a sequence applied by {@code trg_customer_biu}). Snowflake supports
 * neither {@code getGeneratedKeys()}/ROWID nor {@code CURRVAL}, so {@link #insert}
 * re-queries for the generated id and {@link #peekNextId} returns an advisory
 * value only. See docs/MIGRATION.md.</p>
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

    /** Inserts a customer (AUTOINCREMENT id) and re-queries the generated id. */
    public long insert(String firstName, String lastName, String email) {
        String insert =
            "INSERT INTO customer (first_name, last_name, email) VALUES (?, ?, ?)";
        // Snowflake has no getGeneratedKeys()/ROWID and no CURRVAL; re-query the
        // AUTOINCREMENT-assigned id by the row's natural key (email) instead.
        String fetch =
            "SELECT customer_id FROM customer WHERE email = ? ORDER BY customer_id DESC LIMIT 1";
        try (Connection conn = dataSource.getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(insert)) {
                ps.setString(1, firstName);
                ps.setString(2, lastName);
                ps.setString(3, email);
                ps.executeUpdate();
            }
            try (PreparedStatement ps = conn.prepareStatement(fetch)) {
                ps.setString(1, email);
                try (ResultSet keys = ps.executeQuery()) {
                    if (keys.next()) {
                        return keys.getLong(1);
                    }
                }
            }
            throw new DataAccessException("No generated key found for customer insert", null);
        } catch (SQLException e) {
            throw new DataAccessException("insert customer failed", e);
        }
    }

    /** Upsert via the Snowflake MERGE statement (no DUAL) in reports.sql. */
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
     * Advisory next customer id. Oracle read {@code seq_customer_id.NEXTVAL FROM dual};
     * Snowflake AUTOINCREMENT has no peekable CURRVAL/NEXTVAL, so this best-effort
     * value (MAX + 1) is not a reservation and is not gap-free.
     */
    public long peekNextId() {
        String q = "SELECT COALESCE(MAX(customer_id), 99999) + 1 FROM customer";
        try (Connection conn = dataSource.getConnection();
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(q)) {
            return rs.next() ? rs.getLong(1) : -1L;
        } catch (SQLException e) {
            throw new DataAccessException("peekNextId failed", e);
        }
    }
}
