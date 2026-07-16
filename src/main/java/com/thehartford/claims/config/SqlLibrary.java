package com.thehartford.claims.config;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

/**
 * Loads named SQL statements from a classpath resource. Statements are delimited
 * by lines of the form {@code -- name: <id>}.
 */
public final class SqlLibrary {

    private final Map<String, String> statements = new HashMap<>();

    private SqlLibrary() {
    }

    public static SqlLibrary fromResource(String resource) {
        SqlLibrary lib = new SqlLibrary();
        try (InputStream in = SqlLibrary.class.getResourceAsStream(resource)) {
            if (in == null) {
                throw new IllegalStateException("Missing SQL resource: " + resource);
            }
            lib.parse(in);
        } catch (IOException e) {
            throw new IllegalStateException("Failed to load SQL resource " + resource, e);
        }
        return lib;
    }

    public String get(String name) {
        String sql = statements.get(name);
        if (sql == null) {
            throw new IllegalArgumentException("No SQL statement named: " + name);
        }
        return sql;
    }

    private void parse(InputStream in) throws IOException {
        try (BufferedReader reader =
                 new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8))) {
            String current = null;
            StringBuilder buf = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) {
                String trimmed = line.trim();
                if (trimmed.startsWith("-- name:")) {
                    flush(current, buf);
                    current = trimmed.substring("-- name:".length()).trim();
                    buf = new StringBuilder();
                } else if (current != null && !trimmed.startsWith("--")) {
                    buf.append(line).append('\n');
                }
            }
            flush(current, buf);
        }
    }

    private void flush(String name, StringBuilder buf) {
        if (name != null && buf.length() > 0) {
            statements.put(name, buf.toString().trim());
        }
    }
}
