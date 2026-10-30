# HomeGuard Bridge: Node + TVT's Linux NET_SDK. x86_64 only: TVT ships no ARM build.
FROM debian:bookworm-slim AS shim
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev && rm -rf /var/lib/apt/lists/*
COPY native /src
RUN gcc -shared -fPIC -O2 -Wall -Wextra -o /libhg_p2p_serial.so /src/hg_p2p_serial.c -ldl

FROM node:22-bookworm-slim
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY scripts ./scripts
RUN sh scripts/fetch-sdk.sh
COPY --from=shim /libhg_p2p_serial.so /app/vendor/
COPY src ./src
ENV TVT_SDK_DIR=/app/vendor LD_LIBRARY_PATH=/app/vendor
USER node
EXPOSE 8443
CMD ["node", "src/server.mjs"]
