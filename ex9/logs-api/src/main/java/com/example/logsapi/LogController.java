package com.example.logsapi;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

import java.io.IOException;
import java.time.Instant;
import java.util.List;

@RestController
@RequestMapping("/api/v1/logs")
public class LogController {

    private final LogStorage storage;

    public LogController(LogStorage storage) {
        this.storage = storage;
    }

    @GetMapping
    public List<LogEntry> getAllLogs() throws IOException {
        return storage.findAll();
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public LogEntry addLog(@RequestBody LogEntry log) throws IOException {
        if (log.timestamp == null) {
            log.timestamp = Instant.now().toString();
        }
        if (log.level == null) {
            log.level = LogLevel.INFO;
        }
        storage.save(log);
        return log;
    }
}
