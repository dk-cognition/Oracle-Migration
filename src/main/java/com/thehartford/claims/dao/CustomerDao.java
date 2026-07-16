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
 * <p>MIGRATION NOTE: {@link #insert} relies on {@code seq_customer_id.NEXTVAL}
 * being applied by the {@code trg_customer_biu} row trigger, then reads the
 * generated key back with Oracle's {@code getGeneratedKeys()} using ROWID.
 * Snowflake has neither row triggers nor ROWID; use an IDENTITY/AUTOINCREMENT
 * column or an explicit sequence in the INSERT. See docs/MIGRATION.md.</p>
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

    /** Inserts a customer, letting the Oracle trigger assign the id from a sequence. */
    public long insert(String firstName, String lastName, String email) {
        String insert =
            "INSERT INTO hartford.customer (first_name, last_name, email) VALUES (?, ?, ?)";
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps =
                 conn.prepareStatement(insert, new String[] {"CUSTOMER_ID"})) {
            ps.setString(1, firstName);
            ps.setString(2, lastName);
            ps.setString(3, email);
            ps.executeUpdate();
            try (ResultSet keys = ps.getGeneratedKeys()) {
                if (keys.next()) {
                    return keys.getLong(1);
                }
            }
            throw new DataAccessException("No generated key returned for customer insert", null);
        } catch (SQLException e) {
            throw new DataAccessException("insert customer failed", e);
        }
    }

    /** Upsert via the Oracle MERGE ... USING dual statement in reports.sql. */
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

    /** Reads the next customer id straight from the Oracle sequence via DUAL. */
    public long peekNextId() {
        String q = "SELECT hartford.seq_customer_id.NEXTVAL FROM dual";
        try (Connection conn = dataSource.getConnection();
             Statement st = conn.createStatement();
             ResultSet rs = st.executeQuery(q)) {
            return rs.next() ? rs.getLong(1) : -1L;
        } catch (SQLException e) {
            throw new DataAccessException("peekNextId failed", e);
        }
    }
}
