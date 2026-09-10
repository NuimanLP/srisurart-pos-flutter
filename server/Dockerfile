# syntax=docker/dockerfile:1
# Base pinned by digest, not by the floating tag, so a rebuild of an old commit is the
# same image (#61). The tag it resolved from is node:22-alpine. Bump it by re-running
# `docker buildx imagetools inspect node:22-alpine` — never by suppressing a scan finding.
FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS deps
RUN corepack enable
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

FROM deps AS build
COPY tsconfig.json tsconfig.build.json nest-cli.json ./
COPY src ./src
RUN pnpm build && pnpm prune --prod

# node:22-alpine — same digest as the deps stage above.
FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS runtime
ENV NODE_ENV=production
WORKDIR /app
# The image gate (#61) scans this stage for fixable HIGH/CRITICAL, so the image is made
# clean instead of the findings suppressed: `apk upgrade` for Alpine's own advisories,
# then delete the bundled npm/npx (every HIGH/CRITICAL left after that comes from npm's
# own dependency tree). corepack goes with them — it only exists to install a package
# manager, and it vendors npm. Nothing at runtime needs any of it: CMD and every compose
# `command:` are `node dist/…` and the health check uses wget; corepack lives in `deps`.
# Must run before USER node — these files are root-owned.
RUN apk upgrade --no-cache \
 && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
           /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack
USER node
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
COPY --chown=node:node package.json ./
EXPOSE 3000
# Same image runs api (default), worker and bull-board — compose overrides `command`.
CMD ["node", "dist/main.js"]
