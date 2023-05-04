#!/bin/bash

# ==========================
# Generate key for `root`
ssh-keygen -f ./src/root_ssh_key/id_rsa -t rsa -b 4096 -C "reverse-container" -N '' <<<$'\ny' >/dev/null 2>&1
# Generate key for `user`, for example use `natlee` here
ssh-keygen -f ./src/user_ssh_key/id_rsa -t rsa -b 4096 -C "natlee@nat-tunnel" -N '' <<<$'\ny' >/dev/null 2>&1
# ==========================

# Placeholder for authorized keys
rm -f ./src/user_ssh_key/authorized_keys
touch ./src/user_ssh_key/authorized_keys

# ==========================
# Insert public key generating in previous step for self-testing in container
echo $(cat ./src/user_ssh_key/id_rsa.pub) >>./src/user_ssh_key/authorized_keys
# Insert your public key
echo $(cat ~/.ssh/id_rsa.pub) >>./src/user_ssh_key/authorized_keys
# ==========================

# ==========================
# Generate keys for host
ssh-keygen -f ./src/ssh_host_keys/ssh_host_dsa_key -t dsa -C "root@openssh-server" -N '' <<<$'\ny' >/dev/null 2>&1
ssh-keygen -f ./src/ssh_host_keys/ssh_host_rsa_key -t rsa -C "root@openssh-server" -N '' <<<$'\ny' >/dev/null 2>&1
ssh-keygen -f ./src/ssh_host_keys/ssh_host_ecdsa_key -t ecdsa -C "root@openssh-server" -N '' <<<$'\ny' >/dev/null 2>&1
ssh-keygen -f ./src/ssh_host_keys/ssh_host_ed25519_key -t ed25519 -C "root@openssh-server" -N '' <<<$'\ny' >/dev/null 2>&1
# ==========================
