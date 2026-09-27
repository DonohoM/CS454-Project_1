# Pinned major version on a small Alpine base; never a bare `node` or `:latest`.
FROM node:22-alpine

# Production mode for Express and npm; no dev tooling in the image.
ENV NODE_ENV=production

WORKDIR /app

# Copy only the manifests first so the dependency layer is cached until
# package.json / package-lock.json change, then install exactly the locked
# production dependencies.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# Application source. Files stay root-owned, so the runtime user can read but
# not modify them.
COPY src/ ./src/

# Drop root: the official image ships an unprivileged `node` user (uid 1000).
USER node

# Documentation only -- the real port comes from PORT at runtime (see compose.yaml).
EXPOSE 3000

# Exec form so node is PID 1 and receives SIGTERM directly from the runtime.
CMD ["node", "src/server.js"]
