#!/bin/sh
# Runs as root (the image's default user, unlike every other container here
# - see Dockerfile) purely to fix /data's ownership before dropping to the
# non-root `app` user for the actual server process.
#
# Why this has to happen at container start rather than just in the image
# (like every other privilege-drop change in this repo): /data is a named
# volume, and Docker only seeds a *brand-new* volume's ownership from the
# image - it never re-chowns an already-existing one just because the image
# changed. A volume created back when this container still ran as root
# stays root-owned forever otherwise, which is exactly what broke `create_
# entities`/`add_observations` etc. with EACCES the first time this image
# shipped a non-root user for an already-populated /data. Idempotent and
# cheap (a small JSON store), so just always run it.
set -e
chown -R app:app /data
exec su -s /bin/sh app -c "exec node_modules/.bin/supergateway --stdio 'node_modules/.bin/mcp-server-memory' --outputTransport streamableHttp --stateful --port ${MEMORY_MCP_PORT}"
