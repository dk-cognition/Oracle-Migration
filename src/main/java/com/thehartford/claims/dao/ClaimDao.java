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
import java.util.ArrayList;
import java.util.List;

/**
 * Data access for {@link Claim}.
 *
 * <p>Backed by the Snowflake procedures and UDFs in
 * {@code db/snowflake/02_procedures.sql}. Snowflake has no packages and no
 * {@code {? = call ...}} function-call escape: procedures are invoked with a
 * plain {@code CALL} that yields a single-column result set, and scalar UDFs are
 * invoked with a {@code SELECT}.</p>
 */
public class ClaimDao {

    private final DataSource dataSource;

    public ClaimDao() {
        this(DataSourceFactory.get());
    }

    public ClaimDao(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    /** Opens a claim by calling the Snowflake procedure sp_open_claim. */
    public long openClaim(long policyId, LocalDateTime lossDate,
                          String claimType, String description) {
        String call = "CALL hartford.claims.sp_open_claim(?, ?, ?, ?)";
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(call)) {
            ps.setLong(1, policyId);
            ps.setTimestamp(2, Timestamp.valueOf(lossDate));
            ps.setString(3, claimType);
            ps.setString(4, description);
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next()) {
                    return rs.getLong(1);
                }
            }
            throw new DataAccessException(
                "sp_open_claim returned no claim_id for policy " + policyId, null);
        } catch (SQLException e) {
            throw new DataAccessException("sp_open_claim failed for policy " + policyId, e);
        }
    }

    /**
     * Posts a payment against a claim via sp_post_payment, returning the claim
     * status the procedure left it in ({@code OPEN} or {@code CLOSED}).
     */
    public String postPayment(long claimId, BigDecimal amount, String method, String checkNo) {
        String call = "CALL hartford.claims.sp_post_payment(?, ?, ?, ?)";
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
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? rs.getString(1) : null;
            }
        } catch (SQLException e) {
            throw new DataAccessException("sp_post_payment failed for claim " + claimId, e);
        }
    }

    /** Loss ratio via the Snowflake scalar UDF fn_loss_ratio. */
    public BigDecimal lossRatio(long policyId) {
        String query = "SELECT hartford.claims.fn_loss_ratio(?)";
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(query)) {
            ps.setLong(1, policyId);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? rs.getBigDecimal(1) : null;
            }
        } catch (SQLException e) {
            throw new DataAccessException("fn_loss_ratio failed for policy " + policyId, e);
        }
    }

    /** Finds open claims for a policy. */
    public List<Claim> findOpenClaims(long policyId) {
        String sql =
            "SELECT claim_id, claim_number, policy_id, loss_date, reported_date, "
          + "       claim_type, status, reserve_amount, paid_amount, description "
          + "  FROM hartford.claims.claim "
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
