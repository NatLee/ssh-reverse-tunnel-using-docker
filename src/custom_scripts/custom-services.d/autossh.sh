#!/bin/bash

export $(cat /config/.env)

echo "-------- Start AutoSSH"
echo "Reverse server Host is $REVERSE_SERVER_HOST"
echo "Reverse server user is $REVERSE_SERVER_USER_NAME"
echo "Reverse server SSH port is $REVERSE_SERVER_SSH_PORT"
echo "Reverse tunnel port is using $REVERSE_TUNNEL_SSH_PORT"
echo "Reverse using USER is $(whoami)"

/usr/bin/autossh \
    -M 6767 \
    -o "ServerAliveInterval 15" \
    -o "ServerAliveCountMax 3" \
    -o "StrictHostKeyChecking no" \
    -p $REVERSE_SERVER_SSH_PORT \
    -NR '*:'${REVERSE_TUNNEL_SSH_PORT}':localhost:2222' \
    $REVERSE_SERVER_USER_NAME@$REVERSE_SERVER_HOST \
    -i /root/.ssh/id_rsa
