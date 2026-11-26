# Multi-stage build: extract the official hello-world binary, then wrap it in an HTTP server.
# This design allows us to use the exact image linked in the assignment
# (https://hub.docker.com/_/hello-world) while satisfying the requirement that the
# application be "publicly accessible over the internet" via HTTP.

# Extract /hello binary from the official image
FROM library/hello-world:latest as hello

# Final runtime image: Python + extracted binary
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY --chown=10001:10001 app.py .
COPY --from=hello /hello /hello

RUN chmod +x /hello

USER 10001:10001
EXPOSE 8080

# ACA would ignore the health check, only good for local development and testing purposes
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/healthz').read()" || exit 1

CMD ["python", "app.py"]
