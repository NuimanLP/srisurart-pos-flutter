# The web image: static files only — no web server, no configuration (ADR-0013,
# 07_CICD_DEPLOY.md §3). Nginx on the VM stays the stock image with this repo's
# own nginx.conf bind-mounted; cd.1 (#65) copies /web out of this image into the
# volume Nginx serves, the same one-shot pattern certgen already uses.
#
# busybox:stable-musl (1.6 MB) rather than alpine (8.5 MB) or scratch: nothing in
# this image ever serves, but cd.1's one-shot copy needs a shell and `cp`, which
# scratch lacks. busybox's multi-call binary does include an `httpd` applet — it
# is never started: no CMD or EXPOSE here serves anything. Pinned by digest —
# the tag moves.
FROM busybox:stable-musl@sha256:3c6ae8008e2c2eedd141725c30b20d9c36b026eb796688f88205845ef17aa213

# Build context is frontend/ — the workflow builds with `-f ../deploy/web.Dockerfile .`
COPY build/web /web

# Default user = nobody (Trivy DS-0002). COPY still writes /web as root (read-only to this user).
# Honest limit: this does NOT make the deploy rootless. The one place the image runs on a host,
# vm.override.yml's one-shot `web-sync`, sets `user: "0:0"` explicitly, because it writes into
# the `web` volume whose existing files are root-owned. Moving that to a non-root user would need
# a one-time chown of the volume on every host — an owner decision, not part of this change.
USER 65534:65534
