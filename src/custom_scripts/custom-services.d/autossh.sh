#!/usr/bin/with-contenv bash
# shellcheck shell=bash
# Keeps the reverse tunnel open: REVERSE_TUNNEL_SSH_PORT on the outside server
# leads to the sshd in this container. s6 runs this as a service and starts it
# again if it ever exits. The settings come from .env via docker-compose.yml.

# The image's sshd port inside the container (the image's LISTEN_PORT, default 2222).
LOCAL_SSH_PORT=${LISTEN_PORT:-2222}

echo "-------- Start AutoSSH"
echo "[Reverse Server] ${REVERSE_SERVER_USER_NAME}@${REVERSE_SERVER_HOST} port ${REVERSE_SERVER_SSH_PORT}"
echo "[Reverse Server] its port ${REVERSE_TUNNEL_SSH_PORT} leads to localhost:${LOCAL_SSH_PORT} here"

# Keep trying even if the first attempt fails, e.g. while the key is not on
# the outside server yet.
export AUTOSSH_GATETIME=0

# -M 0: no monitor port; ServerAlive* notices a dead link within ~45 seconds.
# ExitOnForwardFailure: if the tunnel port cannot be opened (an old session
# still holds it), exit and retry instead of staying connected without a tunnel.
# accept-new: remember the outside server's host key the first time, then
# refuse a different one.
exec /usr/bin/autossh -M 0 \
    -o "ServerAliveInterval 15" \
    -o "ServerAliveCountMax 3" \
    -o "ExitOnForwardFailure yes" \
    -o "BatchMode yes" \
    -o "StrictHostKeyChecking accept-new" \
    -o "UserKnownHostsFile /root/.ssh/known_hosts" \
    -o "IdentitiesOnly yes" \
    -i /root/.ssh/id_rsa \
    -p "${REVERSE_SERVER_SSH_PORT}" \
    -N -R "*:${REVERSE_TUNNEL_SSH_PORT}:localhost:${LOCAL_SSH_PORT}" \
    "${REVERSE_SERVER_USER_NAME}@${REVERSE_SERVER_HOST}"
