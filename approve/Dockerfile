# The documents approve/discard HTTP surface. Single-file Bun server, no
# dependencies — nothing to install, so no package.json / lockfile. Built locally
# (not pulled from GHCR): the source lives in this repo, same as capture.
#
# Pinned by digest, not just tag. `1-alpine` is mutable, so an unpinned build
# silently adopts whatever it points at that day — the same class of surprise that
# broke CI for five weeks when a trivy-action tag was deleted, and the reason every
# third-party action in this repo is pinned to a full SHA. There is no watchtower
# label here (locally built, nothing to poll), so the flip side is that the base
# only moves when this line is edited. Refresh deliberately, and in step with
# afterimage/Dockerfile, which pins the same digest:
#   docker pull oven/bun:1-alpine \
#     && docker inspect oven/bun:1-alpine --format '{{index .RepoDigests 0}}'
FROM oven/bun@sha256:5acc90a93e91ff07bf72aa90a7c9f0fa189765aec90b47bdbf2152d2196383c0

WORKDIR /app
COPY src/ ./src/

# The image DEFINES uid 1000 ("bun") but does not default to it — Config.User is
# empty, so without this line the container runs as root, and only compose's
# user: "1000:1000" makes it otherwise. Anyone running the image outside compose
# would get root. Setting it here makes the image safe on its own terms.
USER bun

EXPOSE 8080
CMD ["bun", "run", "src/server.ts"]
