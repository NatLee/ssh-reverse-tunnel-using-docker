#!/bin/bash

export $(cat /config/.env)

echo "-------- Start AutoSSH"
echo "[Reverse Server] Host is $REVERSE_SERVER_HOST"
echo "[Reverse Server] User is $REVERSE_SERVER_USER_NAME"
echo "[Reverse Server] SSH port is $REVERSE_SERVER_SSH_PORT"
echo "Use port [$REVERSE_TUNNEL_SSH_PORT] for our reverse tunnel"
echo "Client container is using USER -> $(whoami)"

/usr/bin/autossh \
    -M 6767 \
    -o "ServerAliveInterval 15" \
    -o "ServerAliveCountMax 3" \
    -o "StrictHostKeyChecking no" \
    -p $REVERSE_SERVER_SSH_PORT \
    -NR '*:'${REVERSE_TUNNEL_SSH_PORT}':localhost:2222' \
    $REVERSE_SERVER_USER_NAME@$REVERSE_SERVER_HOST \
    -i /root/.ssh/id_rsa
