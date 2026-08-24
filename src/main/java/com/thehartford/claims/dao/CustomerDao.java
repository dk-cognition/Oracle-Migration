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
 * <p>{@link #insert} obtains the explicit sequence value before inserting,
 * because Snowflake JDBC does not provide generated-key or returning support
 * for this path. See docs/MIGRATION.md.</p>
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

    /** Inserts a customer with an id obtained from the Snowflake sequence. */
    public long insert(String firstName, String lastName, String email) {
        String insert =
            "INSERT INTO hartford.customer "
          + "(customer_id, first_name, last_name, email) VALUES (?, ?, ?, ?)";
        try (Connection conn = dataSource.getConnection()) {
            long customerId;
            try (Statement st = conn.createStatement();
                 ResultSet rs = st.executeQuery("SELECT hartford.seq_customer_id.NEXTVAL")) {
                if (!rs.next()) {
                    throw new DataAccessException("No customer id returned", null);
                }
                customerId = rs.getLong(1);
            }
            try (PreparedStatement ps = conn.prepareStatement(insert)) {
                ps.setLong(1, customerId);
                ps.setString(2, firstName);
                ps.setString(3, lastName);
                ps.setString(4, email);
                ps.executeUpdate();
            }
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

    /** Reads the next customer id straight from the Snowflake sequence. */
    public long peekNextId() {
        String q = "SELECT hartford.seq_customer_id.NEXTVAL";
        try (Connection conn = dataSource.getConnection();
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(q)) {
            return rs.next() ? rs.getLong(1) : -1L;
        } catch (SQLException e) {
            throw new DataAccessException("peekNextId failed", e);
        }
    }
}
