#!/bin/bash
# Koji single-host lab, x86_64. Run as the normal sudo-capable user (rocky) ON the Rocky 10.2 VM, from this directory.
# Usage: bash run-all.sh 2>&1 | tee run-all.log
set -euo pipefail
cd "$(dirname "$0")"
t0=$(date +%s)
step() { echo; echo "######## $1  (+$(( $(date +%s)-t0 ))s)"; }
step 01; sudo bash -s < 01-base.sh
step 02; sudo bash -s < 02-certs.sh
step 03; sudo bash -s < 03-db-hub.sh
step 04; bash -s < 04-client.sh
step 05; bash -s < 05-builder-kojira-web.sh
step 06; bash -s < 06-tags.sh
step 07; bash -s < 07-hello-srpm.sh
step 08; bash -s < 08-build.sh
step done
