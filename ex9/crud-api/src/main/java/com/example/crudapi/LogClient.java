package com.example.crudapi;

import jakarta.servlet.http.HttpServletRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClientException;
import org.springframework.web.client.RestTemplate;

import java.time.Instant;
import java.util.Map;

@Component
public class LogClient {

    private static final Logger logger = LoggerFactory.getLogger(LogClient.class);

    private final RestTemplate restTemplate;
    private final String logsUrl;

    public LogClient(RestTemplate restTemplate, @Value("${logs.api.url}") String logsApiUrl) {
        this.restTemplate = restTemplate;
        this.logsUrl = logsApiUrl + "/api/v1/logs";
    }

    public void send(String level, String message, HttpServletRequest request) {
        Map<String, String> log = Map.of(
                "message", String.valueOf(message),
                "source", "[CrudAPI] " + request.getMethod() + " " + request.getRequestURI(),
                "timestamp", Instant.now().toString(),
                "level", level);
        try {
            restTemplate.postForObject(logsUrl, log, Void.class);
        } catch (RestClientException e) {
            // si l'API de logs est indisponible, le CRUD continue de fonctionner
            logger.warn("Envoi du log impossible : {}", e.getMessage());
        }
    }
}
