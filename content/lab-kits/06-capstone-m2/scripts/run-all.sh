#!/bin/bash
# Build everything from an empty work dir and run the checker. Needs: Rocky 10.2 x86_64, user in group mock,
# passwordless sudo, podman, network to dl.rockylinux.org. ~8 minutes on 4 vCPU. Usage: M=$HOME/m2clean bash scripts/run-all.sh [--experiments]
set -eu; . "$(dirname "$0")/env.sh"
S=$(cd "$(dirname "$0")" && pwd)
T0=$(date +%s); step(){ echo; echo "=================== $* ($(( $(date +%s)-T0 ))s elapsed)"; }
step "01 fetch SRPMs, make keys, render mock config";   bash $S/01-fetch-and-keys.sh
mock -r $M/mock/myorg-10-x86_64.cfg --scrub=all >/dev/null 2>&1 || true   # only OUR root, never the seed's
step "02 build myorg-release (3 packages)";              bash $S/02-build-release.sh
step "03 sign + publish the identity packages";          bash $S/03-sign-publish.sh $M/result/release/*.rpm
if [ "${1:-}" = "--experiments" ]; then
  step "04 conflict experiments";   sudo -E env M=$M HOME=$HOME bash $S/04-conflict-experiments.sh
  step "05 more experiments";       sudo -E env M=$M HOME=$HOME bash $S/05-more-experiments.sh
  step "06 host dry run";           bash $S/06-host-dryrun.sh
fi
step "07 rebuild which + library/consumer";              bash $S/07-rebuild.sh
step "08 publish, installroot, podman image";            bash $S/08-publish-and-image.sh
step "09 failure demos";                                 bash $S/09-failure-demos.sh
step "capstone-check";                                   bash $M/capstone-check.sh
echo; echo "total: $(( $(date +%s)-T0 ))s"
