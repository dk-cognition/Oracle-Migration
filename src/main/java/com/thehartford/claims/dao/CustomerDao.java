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
 * <p>Snowflake has no row triggers, ROWID, or {@code getGeneratedKeys()}, so
 * {@link #insert} draws the id from {@code seq_customer_id} first and inserts
 * it explicitly (the column also defaults to the sequence for other writers).</p>
 */
public class CustomerDao {

    private static final String NEXT_ID = "SELECT seq_customer_id.NEXTVAL";

    private final DataSource dataSource;
    private final SqlLibrary sql;

    public CustomerDao() {
        this(DataSourceFactory.get());
    }

    public CustomerDao(DataSource dataSource) {
        this.dataSource = dataSource;
        this.sql = SqlLibrary.fromResource("/sql/reports.sql");
    }

    /** Inserts a customer and returns its id, drawn from seq_customer_id. */
    public long insert(String firstName, String lastName, String email) {
        String insert =
            "INSERT INTO customer (customer_id, first_name, last_name, email) VALUES (?, ?, ?, ?)";
        try (Connection conn = dataSource.getConnection()) {
            long id = nextId(conn);
            try (PreparedStatement ps = conn.prepareStatement(insert)) {
                ps.setLong(1, id);
                ps.setString(2, firstName);
                ps.setString(3, lastName);
                ps.setString(4, email);
                ps.executeUpdate();
            }
            return id;
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

    /** Draws the next customer id from the sequence (consumes the value, as in Oracle). */
    public long peekNextId() {
        try (Connection conn = dataSource.getConnection()) {
            return nextId(conn);
        } catch (SQLException e) {
            throw new DataAccessException("peekNextId failed", e);
        }
    }

    private static long nextId(Connection conn) throws SQLException {
        try (Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(NEXT_ID)) {
            if (rs.next()) {
                return rs.getLong(1);
            }
        }
        throw new SQLException("seq_customer_id returned no value");
    }
}
