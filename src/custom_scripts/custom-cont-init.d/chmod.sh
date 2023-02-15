#!/bin/bash
echo "-------- Change mode with id_rsa and id_rsa.pub"
chmod 400 /root/.ssh/id_rsa
chmod 644 /root/.ssh/id_rsa.pub

chmod 755 /custom-cont-init.d/*
chmod 755 /custom-services.d/*
