package com.example.logsapi;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.List;

@Component
public class LogStorage {

    private final Path file;
    private final ObjectMapper mapper;

    public LogStorage(@Value("${logs.file}") String file, ObjectMapper mapper) {
        this.file = Path.of(file);
        this.mapper = mapper;
    }

    public synchronized void save(LogEntry log) throws IOException {
        if (file.getParent() != null) {
            Files.createDirectories(file.getParent());
        }
        String line = mapper.writeValueAsString(log) + System.lineSeparator();
        Files.writeString(file, line, StandardCharsets.UTF_8,
                StandardOpenOption.CREATE, StandardOpenOption.APPEND);
    }

    public synchronized List<LogEntry> findAll() throws IOException {
        List<LogEntry> logs = new ArrayList<>();
        if (!Files.exists(file)) {
            return logs;
        }
        for (String line : Files.readAllLines(file, StandardCharsets.UTF_8)) {
            if (!line.isBlank()) {
                logs.add(mapper.readValue(line, LogEntry.class));
            }
        }
        return logs;
    }
}
