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
 * <p>{@link #insert} relies on the {@code customer_id} AUTOINCREMENT default in
 * Snowflake. The driver supports neither {@code getGeneratedKeys()} nor
 * {@code CURRVAL}, so the assigned id is read back by re-querying on the
 * business key just inserted. See docs/MIGRATION.md.</p>
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

    /** Inserts a customer, letting the AUTOINCREMENT column assign the id. */
    public long insert(String firstName, String lastName, String email) {
        String insert =
            "INSERT INTO hartford.customer (first_name, last_name, email) VALUES (?, ?, ?)";
        // Snowflake JDBC supports neither getGeneratedKeys() nor CURRVAL:
        // re-query for the id assigned to the row just inserted.
        String readBack =
            "SELECT MAX(customer_id) FROM hartford.customer "
          + " WHERE first_name = ? AND last_name = ? "
          + "   AND COALESCE(email, '') = COALESCE(?, '')";
        try (Connection conn = dataSource.getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(insert)) {
                ps.setString(1, firstName);
                ps.setString(2, lastName);
                ps.setString(3, email);
                ps.executeUpdate();
            }
            try (PreparedStatement ps = conn.prepareStatement(readBack)) {
                ps.setString(1, firstName);
                ps.setString(2, lastName);
                ps.setString(3, email);
                try (ResultSet rs = ps.executeQuery()) {
                    if (rs.next() && rs.getLong(1) > 0) {
                        return rs.getLong(1);
                    }
                }
            }
            throw new DataAccessException("No generated key found for customer insert", null);
        } catch (SQLException e) {
            throw new DataAccessException("insert customer failed", e);
        }
    }

    /** Upsert via the MERGE statement in reports.sql. */
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
     * Estimates the next customer id. The AUTOINCREMENT default replaces the
     * Oracle sequence + trigger, and Snowflake has no CURRVAL/DUAL, so this
     * peeks at the current maximum instead. Ids are not gap-free; treat the
     * result as advisory only.
     */
    public long peekNextId() {
        String q = "SELECT MAX(customer_id) + 1 FROM hartford.customer";
        try (Connection conn = dataSource.getConnection();
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(q)) {
            return rs.next() ? rs.getLong(1) : -1L;
        } catch (SQLException e) {
            throw new DataAccessException("peekNextId failed", e);
        }
    }
}
