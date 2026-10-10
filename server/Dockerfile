# syntax=docker/dockerfile:1
# Base pinned by digest, not by the floating tag, so a rebuild of an old commit is the
# same image (#61). The tag it resolved from is node:22-alpine. Bump it by re-running
# `docker buildx imagetools inspect node:22-alpine` — never by suppressing a scan finding.
#
# libvips is built from source here, and sharp is compiled against it (2026-10-10). sharp's
# prebuilt @img/sharp-linux*-x64 binaries need an x86-64-v2 CPU (SSE4.2/POPCNT); mob04 is a
# "QEMU Virtual CPU version 2.5+" without them, so `require('sharp')` threw there and the
# ac9d4dd deploy rolled back. Everything built below uses Alpine's baseline x86-64 flags.
# Why not Alpine's own `vips-dev`: Alpine 3.24 ships 8.18.2, and sharp 0.35.5 refuses to build
# against anything older than 8.18.7 (`#error` in src/common.h — 8.18.7 carries the libvips
# CVE fixes that made every older sharp a high in `pnpm audit`). Bump VIPS_VERSION together
# with sharp: its `config.libvips` in node_modules/sharp/package.json is the floor.
FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS libvips
ARG VIPS_VERSION=8.18.7
ARG VIPS_SHA256=5baaead3b0bb20ffdb9e9ff09aa9fda08620923df77b63b436654cb5e0b3bf94
RUN apk add --no-cache build-base meson pkgconf python3 \
      glib-dev expat-dev libjpeg-turbo-dev libpng-dev libwebp-dev libexif-dev lcms2-dev zlib-dev
WORKDIR /src
# Only what the product-image pipeline needs: JPEG/PNG/WebP in, WebP out, EXIF (autoOrient),
# lcms (ICC → sRGB). --auto-features=disabled keeps every other loader (SVG/librsvg, HEIF,
# TIFF, PDF, GIF, …) out of the build, so none of their CVEs can reach this image.
RUN wget -q -O vips.tar.xz \
      "https://github.com/libvips/libvips/releases/download/v${VIPS_VERSION}/vips-${VIPS_VERSION}.tar.xz" \
 && echo "${VIPS_SHA256}  vips.tar.xz" | sha256sum -c - \
 && tar xf vips.tar.xz \
 && meson setup build "vips-${VIPS_VERSION}" --prefix=/usr/local --libdir=lib --buildtype=release \
      --auto-features=disabled -Ddeprecated=false -Dexamples=false \
      -Dnsgif=false -Dppm=false -Danalyze=false -Dradiance=false \
      -Djpeg=enabled -Dpng=enabled -Dwebp=enabled -Dexif=enabled -Dlcms=enabled -Dzlib=enabled \
 && meson install -C build --strip \
 && mkdir /vips-runtime && cp -a /usr/local/lib/libvips*.so.* /vips-runtime/ \
 && rm -rf /src

FROM libvips AS deps
RUN corepack enable
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
# sharp has no install script: pnpm only links its prebuilt optional @img/* packages. Compile it
# against /usr/local's libvips (found via pkg-config) with the pinned node-gyp/node-addon-api
# devDependencies. The result lands in sharp/src/build/Release, which sharp tries first.
# nodedir: the base image's own headers, so node-gyp downloads nothing.
RUN cd node_modules/sharp \
 && PATH="/app/node_modules/.bin:$PATH" npm_config_nodedir=/usr/local node install/build.js \
 && mv src/build/Release/sharp-*.node /tmp/ && rm -rf src/build \
 && mkdir -p src/build/Release && mv /tmp/sharp-*.node src/build/Release/

FROM deps AS build
COPY tsconfig.json tsconfig.build.json nest-cli.json ./
COPY src ./src
# After the prune: drop the prebuilt @img/sharp-* packages (and their links) so the runtime
# image cannot load a v2-only binary, then prove the compiled one loads.
RUN pnpm build && pnpm prune --prod \
 && rm -rf node_modules/.pnpm/@img+sharp-* node_modules/.pnpm/sharp@*/node_modules/@img/sharp-* \
 && node -e "const s=require('sharp'); console.log('sharp', s.versions.sharp, 'libvips', s.versions.vips)"

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
# The `apk add` list is every shared library libvips.so/libvips-cpp.so/sharp.node need
# (`scanelf --needed`) that the base lacks — the runtime half of the libvips stage's -dev list,
# no headers, no compiler. A missing one fails server.yml's sharp check, not silently at boot.
# Must run before USER node — these files are root-owned.
RUN apk upgrade --no-cache \
 && apk add --no-cache glib libexpat libjpeg-turbo libpng libwebp libwebpmux libwebpdemux libexif lcms2 \
 && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
           /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
 && mkdir -p /app/exports /app/product-images  && chown node:node /app/exports /app/product-images
# /app/exports: mount point of the `exports` volume (tenant export files, EXPORT_DIR);
# /app/product-images: of the `product-images` volume (PRODUCT_IMAGES_DIR). Created here, owned
# by node, so Docker seeds a fresh named volume with that ownership.
# libvips (built above) goes in musl's default search path; sharp.node links libvips-cpp.so.42.
COPY --from=libvips /vips-runtime/ /usr/local/lib/
USER node
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
COPY --chown=node:node package.json ./
EXPOSE 3000
# The commit this image was built from, for GET /platform/system (#443). Only the release job
# (server.yml build-image) passes it; a local build leaves it empty and the API reports null.
# Declared last so it invalidates no earlier layer.
ARG GIT_SHA=""
ENV GIT_SHA=$GIT_SHA
# Same image runs api (default), worker and bull-board — compose overrides `command`.
CMD ["node", "dist/main.js"]
