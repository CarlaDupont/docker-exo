package com.example.crudapi;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.method.HandlerMethod;
import org.springframework.web.servlet.HandlerInterceptor;

@Component
public class LogInterceptor implements HandlerInterceptor {

    private final LogClient logClient;

    public LogInterceptor(LogClient logClient) {
        this.logClient = logClient;
    }

    // les erreurs sont envoyées par ErrorHandler, ici seulement les appels réussis
    @Override
    public void afterCompletion(HttpServletRequest request, HttpServletResponse response, Object handler, Exception ex) {
        if (handler instanceof HandlerMethod && response.getStatus() < 400) {
            logClient.send("INFO", "Appel réussi (" + response.getStatus() + ")", request);
        }
    }
}
