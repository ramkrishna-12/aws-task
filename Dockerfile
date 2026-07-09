# syntax=docker/dockerfile:1

# ---------- Stage 1: Build & Test ----------
# Full JDK is only needed to compile + run tests; it never ships in the final image.
FROM eclipse-temurin:17-jdk-jammy AS build

WORKDIR /workspace

# Cache Gradle dependencies separately from source so code changes don't bust the dependency cache
COPY gradlew settings.gradle build.gradle ./
COPY gradle ./gradle
RUN chmod +x gradlew && ./gradlew --no-daemon dependencies || true

COPY src ./src

# Compile, run unit/integration tests, then package. Build fails the whole Docker build if tests fail.
RUN ./gradlew --no-daemon clean test bootJar

# Explode the boot jar into its dependency layers (dependencies / spring-boot-loader / snapshot-deps / application)
# so Docker layer caching only re-uploads the tiny "application" layer on most code changes.
RUN mkdir -p /workspace/extracted && \
    java -Djarmode=layertools -jar build/libs/*.jar extract --destination /workspace/extracted

# ---------- Stage 2: Minimal runtime ----------
# jre (not jdk) + alpine-style slim base keeps the shipped image small and reduces attack surface.
FROM eclipse-temurin:17-jre-jammy AS runtime

# Run as a non-root, unprivileged user (security best practice, also required by many ECS task defs)
RUN groupadd -r spring && useradd -r -g spring -d /app spring
WORKDIR /app

# Copy layers in order of change-frequency (least -> most likely to change)
COPY --from=build /workspace/extracted/dependencies/ ./
COPY --from=build /workspace/extracted/spring-boot-loader/ ./
COPY --from=build /workspace/extracted/snapshot-dependencies/ ./
COPY --from=build /workspace/extracted/application/ ./

USER spring
EXPOSE 8080

# Used by ECS container health check / ALB target group
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/actuator/health | grep -q '"status":"UP"' || exit 1

ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]
