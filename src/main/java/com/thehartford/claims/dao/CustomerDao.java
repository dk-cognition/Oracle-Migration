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
 * <p>Snowflake supports neither row triggers nor {@code getGeneratedKeys()}, so
 * {@link #insert} draws the key from {@code seq_customer_id} up front, inserts it
 * explicitly, and re-queries the row to confirm it landed. See docs/MIGRATION.md.</p>
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

    /** Inserts a customer with an id taken from the Snowflake sequence, then re-queries it. */
    public long insert(String firstName, String lastName, String email) {
        String insert =
            "INSERT INTO customer (customer_id, first_name, last_name, email) VALUES (?, ?, ?, ?)";
        String reselect = "SELECT customer_id FROM customer WHERE customer_id = ?";
        long customerId = peekNextId();
        try (Connection conn = dataSource.getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(insert)) {
                ps.setLong(1, customerId);
                ps.setString(2, firstName);
                ps.setString(3, lastName);
                ps.setString(4, email);
                ps.executeUpdate();
            }
            try (PreparedStatement ps = conn.prepareStatement(reselect)) {
                ps.setLong(1, customerId);
                try (ResultSet rs = ps.executeQuery()) {
                    if (rs.next()) {
                        return rs.getLong(1);
                    }
                }
            }
            throw new DataAccessException(
                "Inserted customer " + customerId + " could not be read back", null);
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

    /** Reads the next customer id straight from the Snowflake sequence (no DUAL). */
    public long peekNextId() {
        String q = "SELECT seq_customer_id.NEXTVAL";
        try (Connection conn = dataSource.getConnection();
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(q)) {
            return rs.next() ? rs.getLong(1) : -1L;
        } catch (SQLException e) {
            throw new DataAccessException("peekNextId failed", e);
        }
    }
}
