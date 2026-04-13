# Runtime-only Dockerfile
# Application build is handled in GitHub Actions

ARG JAVA_VERSION=17
FROM eclipse-temurin:${JAVA_VERSION}-jre-jammy

WORKDIR /app

# Run as non-root user
RUN useradd -r -U -u 10001 appuser

# Copy the JAR prepared by the workflow
COPY build/libs/app.jar /app/app.jar

USER 10001

EXPOSE 8080

ENTRYPOINT ["java", "-jar", "/app/app.jar"]