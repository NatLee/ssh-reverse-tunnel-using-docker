#!/bin/bash
# Runs as root every time the container starts. ssh refuses a private key
# that other users can read.
echo "-------- Change mode with id_rsa and id_rsa.pub"
chmod 400 /root/.ssh/id_rsa
chmod 644 /root/.ssh/id_rsa.pub
