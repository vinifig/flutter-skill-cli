# Flutter Skill - AI Agent Bridge for Flutter Apps
# Multi-stage build for minimal image size

# Stage 1: Build
FROM dart:stable AS builder

WORKDIR /app

# Copy pubspec files first for better caching
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

# Copy source code
COPY bin/ bin/
COPY lib/ lib/

# Compile to native executable
RUN dart compile exe bin/flutter_skill.dart -o flutter_skill

# Stage 2: Runtime
FROM debian:bookworm-slim

# Install required runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -m -s /bin/bash flutter_skill

# Copy compiled binary
COPY --from=builder /app/flutter_skill /usr/local/bin/flutter_skill

# Set ownership
RUN chown flutter_skill:flutter_skill /usr/local/bin/flutter_skill

# Switch to non-root user
USER flutter_skill
WORKDIR /home/flutter_skill

# Default command runs the MCP server
ENTRYPOINT ["flutter_skill"]
CMD ["server"]

# Labels for GitHub Container Registry
LABEL org.opencontainers.image.source="https://github.com/ai-dashboad/flutter-skill"
LABEL org.opencontainers.image.description="AI Agent Bridge for Flutter Apps - Connect Claude, Cursor, and other AI agents to running Flutter applications"
LABEL org.opencontainers.image.licenses="MIT"
