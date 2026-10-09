package com.thehartford.claims.dao;

import com.thehartford.claims.config.DataSourceFactory;
import com.thehartford.claims.model.Claim;

import javax.sql.DataSource;
import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.sql.Types;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;

/**
 * Data access for {@link Claim}.
 *
 * <p>The former PL/SQL package {@code claims_pkg} is now a set of standalone
 * Snowflake objects (db/snowflake/02_procedures.sql). Snowflake JDBC has no OUT
 * parameters, so procedures are invoked with {@code CALL} and their single return
 * value is read from the result set; scalar UDFs are invoked with {@code SELECT}.</p>
 */
public class ClaimDao {

    private static final DateTimeFormatter NTZ_FORMAT =
        DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss.SSSSSSSSS");

    private final DataSource dataSource;

    public ClaimDao() {
        this(DataSourceFactory.get());
    }

    public ClaimDao(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    /** Opens a claim via the claims_open_claim procedure and returns the new claim_id. */
    public long openClaim(long policyId, LocalDateTime lossDate,
                          String claimType, String description) {
        // Loss date is bound as text and parsed server-side so the TIMESTAMP_NTZ
        // value is not shifted by JVM vs. session time zone differences.
        String call = "CALL claims_open_claim(?, TO_TIMESTAMP_NTZ(?, 'YYYY-MM-DD HH24:MI:SS.FF9'), ?, ?)";
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(call)) {
            ps.setLong(1, policyId);
            ps.setString(2, NTZ_FORMAT.format(lossDate));
            ps.setString(3, claimType);
            ps.setString(4, description);
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next()) {
                    return rs.getLong(1);
                }
            }
            throw new DataAccessException("claims_open_claim returned no claim_id for policy " + policyId, null);
        } catch (SQLException e) {
            throw new DataAccessException("open_claim failed for policy " + policyId, e);
        }
    }

    /** Posts a payment against a claim via the claims_post_payment procedure. */
    public void postPayment(long claimId, BigDecimal amount, String method, String checkNo) {
        String call = "CALL claims_post_payment(?, ?, ?, ?)";
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(call)) {
            ps.setLong(1, claimId);
            ps.setBigDecimal(2, amount);
            ps.setString(3, method);
            if (checkNo == null) {
                ps.setNull(4, Types.VARCHAR);
            } else {
                ps.setString(4, checkNo);
            }
            ps.execute();
        } catch (SQLException e) {
            throw new DataAccessException("post_payment failed for claim " + claimId, e);
        }
    }

    /** Loss ratio via the claims_loss_ratio UDF; fails if the policy does not exist. */
    public BigDecimal lossRatio(long policyId) {
        String query = "SELECT claims_loss_ratio(?)";
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(query)) {
            ps.setLong(1, policyId);
            try (ResultSet rs = ps.executeQuery()) {
                BigDecimal ratio = rs.next() ? rs.getBigDecimal(1) : null;
                if (ratio == null) {
                    throw new DataAccessException("No policy found with id " + policyId, null);
                }
                return ratio;
            }
        } catch (SQLException e) {
            throw new DataAccessException("loss_ratio failed for policy " + policyId, e);
        }
    }

    /** Finds open claims for a policy, newest first. */
    public List<Claim> findOpenClaims(long policyId) {
        String sql =
            "SELECT claim_id, claim_number, policy_id, loss_date, reported_date, "
          + "       claim_type, status, reserve_amount, paid_amount, description "
          + "  FROM claim "
          + " WHERE policy_id = ? "
          + "   AND status IN ('OPEN', 'INVESTIGATING') "
          + " ORDER BY reported_date DESC";

        List<Claim> results = new ArrayList<>();
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {
            ps.setLong(1, policyId);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    results.add(map(rs));
                }
            }
        } catch (SQLException e) {
            throw new DataAccessException("findOpenClaims failed for policy " + policyId, e);
        }
        return results;
    }

    private Claim map(ResultSet rs) throws SQLException {
        Claim c = new Claim();
        c.setClaimId(rs.getLong("claim_id"));
        c.setClaimNumber(rs.getString("claim_number"));
        c.setPolicyId(rs.getLong("policy_id"));
        c.setLossDate(toLdt(rs.getTimestamp("loss_date")));
        c.setReportedDate(toLdt(rs.getTimestamp("reported_date")));
        c.setClaimType(rs.getString("claim_type"));
        c.setStatus(rs.getString("status"));
        c.setReserveAmount(rs.getBigDecimal("reserve_amount"));
        c.setPaidAmount(rs.getBigDecimal("paid_amount"));
        c.setDescription(rs.getString("description"));
        return c;
    }

    private static LocalDateTime toLdt(Timestamp ts) {
        return ts == null ? null : ts.toLocalDateTime();
    }
}
