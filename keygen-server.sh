#!/bin/bash

# Placeholder for authorized keys
rm -f ./src/server-config/root_ssh_key/authorized_keys
touch ./src/server-config/root_ssh_key/authorized_keys

# Generate keys for outside server
ssh-keygen -f ./src/server-config/ssh_host_keys/ssh_host_dsa_key -t dsa -C "root@openssh-outside-server" -N '' <<<$'\ny' >/dev/null 2>&1
ssh-keygen -f ./src/server-config/ssh_host_keys/ssh_host_rsa_key -t rsa -C "root@openssh-outside-server" -N '' <<<$'\ny' >/dev/null 2>&1
ssh-keygen -f ./src/server-config/ssh_host_keys/ssh_host_ecdsa_key -t ecdsa -C "root@openssh-outside-server" -N '' <<<$'\ny' >/dev/null 2>&1
ssh-keygen -f ./src/server-config/ssh_host_keys/ssh_host_ed25519_key -t ed25519 -C "root@openssh-outside-server" -N '' <<<$'\ny' >/dev/null 2>&1
