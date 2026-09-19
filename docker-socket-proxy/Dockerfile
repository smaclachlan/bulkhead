# Filtering reverse proxy in front of the host's Docker socket - see
# templates/default.conf.template and README's "Docker socket proxy"
# section for what it enforces and why this replaced
# tecnativa/docker-socket-proxy (ADR-0002 Decision 3).
#
# Built via `nix run .#build-docker-socket-proxy-image` (see flake.nix).
FROM nginx:alpine

# nginx:alpine's own entrypoint envsubst's every *.template file under
# /etc/nginx/templates/ into /etc/nginx/conf.d/ (stripping the .template
# suffix) before nginx starts - that's what resolves
# ${WORKSPACE_CONTAINER_NAME} at container start, no custom entrypoint
# script needed.
COPY templates/default.conf.template /etc/nginx/templates/default.conf.template

EXPOSE 2375
