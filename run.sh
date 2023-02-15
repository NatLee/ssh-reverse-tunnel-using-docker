#!/bin/bash

echo "---- Chang mode with SSH host keys"
chmod 600 ./src/ssh_host_keys/ssh_*
chmod 644 ./src/ssh_host_keys/ssh_*.pub

echo "---- Chang mode with root SSH key"
chmod 600 ./src/root_ssh_key/id_rsa
chmod 644 ./src/root_ssh_key/id_rsa.pub

echo "---- Chang mode with user SSH key"
chmod 600 ./src/user_ssh_key/id_rsa
chmod 644 ./src/user_ssh_key/id_rsa.pub

echo "---- Chang owner with custom_scripts"
chown -R $USER:$USER ./src/custom_scripts/custom-cont-init.d
chown -R $USER:$USER ./src/custom_scripts/custom-services.d

echo "---- Chang mode with custom_scripts"
chmod 755 ./src/custom_scripts/custom-cont-init.d/*
chmod 755 ./src/custom_scripts/custom-services.d/*

echo "---- Display public key used in AutoSSH"
echo $(cat ./src/root_ssh_key/id_rsa.pub)

echo "---- Starting service"
docker-compose up
