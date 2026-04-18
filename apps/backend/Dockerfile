# ============================================================
# Multi-stage Dockerfile — Node.js Backend API
# ============================================================

# ---- Stage 1: Dependencies ----
FROM node:20-alpine AS deps
LABEL stage=deps

WORKDIR /app

# Install only production dependencies first (layer cache)
COPY package.json package-lock.json ./
RUN npm ci --only=production --ignore-scripts && \
    cp -R node_modules /tmp/prod-node-modules

# Install all dependencies (including devDeps for build)
RUN npm ci --ignore-scripts

# ---- Stage 2: Builder ----
FROM node:20-alpine AS builder
LABEL stage=builder

ARG BUILD_DATE
ARG GIT_SHA
ARG GIT_BRANCH

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Type check + build
RUN npm run type-check && \
    npm run build

# ---- Stage 3: Tester ----
FROM builder AS tester
LABEL stage=tester

ENV NODE_ENV=test

RUN npm run test:unit -- --passWithNoTests

# ---- Stage 4: Production Runtime ----
FROM node:20-alpine AS runtime

# Security: add non-root user
RUN addgroup -g 1000 appgroup && \
    adduser -u 1000 -G appgroup -s /bin/sh -D appuser

# Install dumb-init for proper signal handling
RUN apk add --no-cache dumb-init curl

WORKDIR /app

# Copy production node_modules (no devDependencies)
COPY --from=deps /tmp/prod-node-modules ./node_modules

# Copy compiled application
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/package.json ./

# Copy migration files
COPY --from=builder /app/src/db/migrations ./src/db/migrations

# Set build metadata
ARG BUILD_DATE
ARG GIT_SHA
ARG GIT_BRANCH

ENV NODE_ENV=production \
    PORT=8080 \
    BUILD_DATE=${BUILD_DATE} \
    GIT_SHA=${GIT_SHA} \
    GIT_BRANCH=${GIT_BRANCH}

# OCI Labels
LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="https://github.com/your-org/backend" \
      org.opencontainers.image.title="Backend API" \
      org.opencontainers.image.description="GitOps Demo Backend Service" \
      org.opencontainers.image.vendor="Your Org"

# Use non-root user
USER appuser

EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -f http://localhost:8080/health/live || exit 1

# dumb-init ensures proper PID 1 signal handling
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "dist/main.js"]
