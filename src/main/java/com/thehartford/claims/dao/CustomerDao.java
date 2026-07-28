package com.thehartford.claims.dao;

import com.thehartford.claims.config.DataSourceFactory;
import com.thehartford.claims.config.SqlLibrary;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;

/**
 * Data access for customers.
 *
 * <p>{@code customer_id} is now filled in by the {@code seq_customer_id.NEXTVAL}
 * column default instead of the {@code trg_customer_biu} row trigger. Snowflake
 * supports neither {@code getGeneratedKeys()} nor {@code CURRVAL}, so
 * {@link #insert} re-queries the row it just wrote to learn the generated id.
 * See docs/MIGRATION.md.</p>
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

    /**
     * Inserts a customer, letting the sequence column default assign the id, then
     * re-queries for that id (Snowflake has no generated-key support).
     */
    public long insert(String firstName, String lastName, String email) {
        String insert =
            "INSERT INTO hartford.claims.customer (first_name, last_name, email) "
          + "VALUES (?, ?, ?)";
        String reread =
            "SELECT MAX(customer_id) FROM hartford.claims.customer "
          + " WHERE first_name = ? AND last_name = ? AND email = ?";
        try (Connection conn = dataSource.getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(insert)) {
                ps.setString(1, firstName);
                ps.setString(2, lastName);
                ps.setString(3, email);
                ps.executeUpdate();
            }
            try (PreparedStatement ps = conn.prepareStatement(reread)) {
                ps.setString(1, firstName);
                ps.setString(2, lastName);
                ps.setString(3, email);
                try (ResultSet rs = ps.executeQuery()) {
                    if (rs.next()) {
                        long id = rs.getLong(1);
                        if (!rs.wasNull()) {
                            return id;
                        }
                    }
                }
            }
            throw new DataAccessException(
                "Could not re-read the generated id for customer insert", null);
        } catch (SQLException e) {
            throw new DataAccessException("insert customer failed", e);
        }
    }

    /** Upsert via the Snowflake MERGE statement in reports.sql. */
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
     * Draws an id from the customer sequence (no DUAL in Snowflake). Snowflake
     * sequences are not gap-free, so the value is consumed, not merely peeked:
     * pass it explicitly to an INSERT if it must be used.
     */
    public long peekNextId() {
        String q = "SELECT hartford.claims.seq_customer_id.NEXTVAL";
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(q);
             ResultSet rs = ps.executeQuery()) {
            return rs.next() ? rs.getLong(1) : -1L;
        } catch (SQLException e) {
            throw new DataAccessException("peekNextId failed", e);
        }
    }
}
