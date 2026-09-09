# The indexer is a long-lived worker that also answers reads. It holds a SQLite file and no key.
FROM node:22-alpine

WORKDIR /app

# Dependencies first, so a code change does not reinstall them.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY indexer.ts ./
COPY src ./src

# The database lives on a volume. Losing it costs a resync rather than data, but resyncing on
# every restart is waste, and the price history it holds goes back further than the deploy block.
RUN mkdir -p /data && chown node:node /data
VOLUME ["/data"]
ENV DATABASE_PATH=/data/safix-index.db

USER node

# JSON lines, for whatever collects logs on the host.
ENV LOG_FORMAT=json
ENV CONFIG=/app/config.json
ENV PORT=8080
EXPOSE 8080

# No secret of any kind: the indexer reads the chain and serves reads. RPC_URL may be set to point
# at a private node; nothing else is needed.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD wget -qO- http://127.0.0.1:8080/health || exit 1

CMD ["npx", "tsx", "indexer.ts", "watch"]
