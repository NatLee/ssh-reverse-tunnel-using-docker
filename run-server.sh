#!/bin/bash

echo "#### RUNNING REVERSE SERVER"

echo "---- Starting service"
docker-compose -f docker-compose.server.yml up
