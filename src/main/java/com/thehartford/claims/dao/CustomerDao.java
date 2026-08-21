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
 * <p>Snowflake has no row triggers, no ROWID, and no
 * {@code getGeneratedKeys()}/{@code CURRVAL}, so {@link #insert} draws the id
 * from {@code seq_customer_id.NEXTVAL} up front and binds it explicitly rather
 * than reading a generated key back.</p>
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

    /** Inserts a customer with an id claimed from the sequence, and returns it. */
    public long insert(String firstName, String lastName, String email) {
        String insert =
            "INSERT INTO hartford.claims.customer (customer_id, first_name, last_name, email) "
          + "VALUES (?, ?, ?, ?)";
        long customerId = nextId();
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(insert)) {
            ps.setLong(1, customerId);
            ps.setString(2, firstName);
            ps.setString(3, lastName);
            ps.setString(4, email);
            ps.executeUpdate();
            return customerId;
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
     * Claims the next customer id from the sequence (no {@code FROM dual}).
     * Snowflake sequences are not gap-free, so the value is consumed, not peeked:
     * callers must use it or discard it.
     */
    public long nextId() {
        String q = "SELECT hartford.claims.seq_customer_id.NEXTVAL";
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(q);
             ResultSet rs = ps.executeQuery()) {
            return rs.next() ? rs.getLong(1) : -1L;
        } catch (SQLException e) {
            throw new DataAccessException("nextId failed", e);
        }
    }
}
