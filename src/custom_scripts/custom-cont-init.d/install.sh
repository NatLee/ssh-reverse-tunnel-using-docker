#!/bin/bash
# Runs as root every time the container starts. autossh is not part of the
# image, so add it the first time. A restarted container still has it and
# does not need the network for this.
if command -v autossh >/dev/null 2>&1; then
    echo "-------- AutoSSH is already installed"
else
    echo "-------- Install AUTOSSH"
    apk add --no-cache autossh
fi
