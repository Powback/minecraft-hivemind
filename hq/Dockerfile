# HQ — the out-of-world brain. Small on purpose: it holds no game state and can
# be restarted freely; the in-world Bridge reconnects on its own backoff.
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --omit=dev=false --silent
COPY tsconfig.json ./
COPY src ./src
RUN npx tsc -p .

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json* ./
RUN npm install --omit=dev --silent
COPY --from=build /app/dist ./dist
# The /map page and its vendored Three.js. Baked in rather than mounted: unlike lua/, this is not
# something anyone edits in place at runtime, and a page served from a different revision than the
# endpoints it polls is a debugging trap with no upside.
COPY public ./public
# The Lua tree is BIND-MOUNTED, not baked in: editing a drone module and running
# Sync must not require rebuilding this image.
ENV LUA_DIR=/lua
EXPOSE 4400
CMD ["node", "dist/server.js"]
