package com.taskmaster.taskmaster.controller;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.util.List;
import java.util.Map;

@RestController
public class TaskController {

    @GetMapping("/")
    public Map<String, Object> root() {
        return Map.of(
                "service", "taskmaster",
                "status", "UP",
                "timestamp", Instant.now().toString()
        );
    }

    @GetMapping("/api/tasks")
    public List<Map<String, Object>> tasks() {
        return List.of(
                Map.of("id", 1, "title", "Set up CI/CD", "done", true),
                Map.of("id", 2, "title", "Provision ECS", "done", false)
        );
    }
}
