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
 * <p>Calls the Snowflake procedures migrated from the Oracle {@code claims_pkg}
 * package. Snowflake procedures are invoked with {@code CALL proc(...)} and
 * return a single scalar/variant value as a one-row result set rather than a
 * bound OUT parameter. See docs/MIGRATION.md.</p>
 */
public class ClaimDao {

    private final DataSource dataSource;

    public ClaimDao() {
        this(DataSourceFactory.get());
    }

    public ClaimDao(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    /** Opens a claim by calling the Snowflake procedure open_claim. */
    public long openClaim(long policyId, LocalDateTime lossDate,
                          String claimType, String description) {
        String call = "CALL open_claim(?, ?, ?, ?)";
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
            throw new DataAccessException("open_claim returned no value for policy " + policyId, null);
        } catch (SQLException e) {
            throw new DataAccessException("open_claim failed for policy " + policyId, e);
        }
    }

    /** Posts a payment against a claim via the Snowflake procedure post_payment. */
    public void postPayment(long claimId, BigDecimal amount, String method, String checkNo) {
        String call = "CALL post_payment(?, ?, ?, ?)";
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

    /** Loss ratio via the Snowflake procedure loss_ratio. */
    public BigDecimal lossRatio(long policyId) {
        String call = "CALL loss_ratio(?)";
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(call)) {
            ps.setLong(1, policyId);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? rs.getBigDecimal(1) : null;
            }
        } catch (SQLException e) {
            throw new DataAccessException("loss_ratio failed for policy " + policyId, e);
        }
    }

    /** Finds open claims for a policy. */
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
