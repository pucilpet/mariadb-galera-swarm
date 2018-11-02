#!/bin/bash
set -e
IMAGE=${1?"Usage: $0 IMAGE_NAME"}
docker network create cm-galera-test
docker run --rm -d --name cm-galera-test-seed -e XTRABACKUP_PASSWORD=foobar                    --network cm-galera-test --network-alias seed $IMAGE seed
sleep 3
docker run --rm    --name cm-galera-test-node -e XTRABACKUP_PASSWORD=foobar -e GCOMM_MINIMUM=1 --network cm-galera-test $IMAGE node seed
echo "Cleaning up..."
docker stop cm-galera-test-seed
docker network rm cm-galera-test
