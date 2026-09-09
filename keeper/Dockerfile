# The keeper is a long-lived process, not a request handler: it holds a loop, a key and a little
# state about which positions have been stuck. Any host that restarts a container on exit works.
FROM node:22-alpine

WORKDIR /app

# Dependencies first, so a code change does not reinstall them.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY keeper.ts ./
COPY src ./src

# Run unprivileged. The process needs no filesystem writes beyond its own logs.
USER node

# JSON lines, for whatever collects logs on the host.
ENV LOG_FORMAT=json

# PRIVATE_KEY and ALERT_WEBHOOK_URL come from the host's secret store, never from the image.
# CONFIG points at a mounted config.json, or the baked default below.
ENV CONFIG=/app/config.json

CMD ["npx", "tsx", "keeper.ts", "watch"]
