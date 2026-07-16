package com.thehartford.claims.dao;

/** Unchecked wrapper for SQL failures in the data access layer. */
public class DataAccessException extends RuntimeException {

    public DataAccessException(String message, Throwable cause) {
        super(message, cause);
    }
}
