package com.thehartford.claims.model;

import java.math.BigDecimal;
import java.time.LocalDateTime;

/** A claim booked against a policy. */
public class Claim {

    private long claimId;
    private String claimNumber;
    private long policyId;
    private LocalDateTime lossDate;
    private LocalDateTime reportedDate;
    private String claimType;
    private String status;
    private BigDecimal reserveAmount;
    private BigDecimal paidAmount;
    private String description;

    public long getClaimId() {
        return claimId;
    }

    public void setClaimId(long claimId) {
        this.claimId = claimId;
    }

    public String getClaimNumber() {
        return claimNumber;
    }

    public void setClaimNumber(String claimNumber) {
        this.claimNumber = claimNumber;
    }

    public long getPolicyId() {
        return policyId;
    }

    public void setPolicyId(long policyId) {
        this.policyId = policyId;
    }

    public LocalDateTime getLossDate() {
        return lossDate;
    }

    public void setLossDate(LocalDateTime lossDate) {
        this.lossDate = lossDate;
    }

    public LocalDateTime getReportedDate() {
        return reportedDate;
    }

    public void setReportedDate(LocalDateTime reportedDate) {
        this.reportedDate = reportedDate;
    }

    public String getClaimType() {
        return claimType;
    }

    public void setClaimType(String claimType) {
        this.claimType = claimType;
    }

    public String getStatus() {
        return status;
    }

    public void setStatus(String status) {
        this.status = status;
    }

    public BigDecimal getReserveAmount() {
        return reserveAmount;
    }

    public void setReserveAmount(BigDecimal reserveAmount) {
        this.reserveAmount = reserveAmount;
    }

    public BigDecimal getPaidAmount() {
        return paidAmount;
    }

    public void setPaidAmount(BigDecimal paidAmount) {
        this.paidAmount = paidAmount;
    }

    public String getDescription() {
        return description;
    }

    public void setDescription(String description) {
        this.description = description;
    }

    @Override
    public String toString() {
        return "Claim{" + claimNumber + ", policy=" + policyId
            + ", status=" + status + ", paid=" + paidAmount + '}';
    }
}
