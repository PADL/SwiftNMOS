#!/usr/bin/env bash
# Fetches the AMWA NMOS specifications this implementation is written against, so
# their schemas, models and examples can be read and tested against locally. They
# are the ground truth: other implementations are a reference for behaviour only.
#
# Each repository is cloned shallowly into .build/nmos-specs/, which git ignores and
# the package build does not scan, at the branch that carries the version we
# target, or fast-forwarded if it is already there.
#
# Usage: scripts/nmos/fetch-specs.sh [destination]
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-$DIR/../../.build/nmos-specs}"

# repository:branch
SPECS=(
  is-04:v1.3.x                    # Discovery and Registration
  is-05:v1.2.x                    # Device Connection Management
  is-12:v1.0.x                    # Control Protocol
  ms-05-01:v1.0.x                 # Control Architecture (class ID format)
  ms-05-02:v1.0.x                 # Control Framework (class and datatype models)
  nmos-control-feature-sets:main  # NcIdentBeacon, NcReceiverMonitor, NcSenderMonitor
  nmos-parameter-registers:main   # transports, device control types, capabilities
  bcp-004-01:v1.0.x               # Receiver Capabilities
  bcp-008-01:v1.0.x               # Receiver Status Monitoring
  bcp-008-02:v1.0.x               # Sender Status Monitoring
)

mkdir -p "$DEST"
for spec in "${SPECS[@]}"; do
  name="${spec%%:*}"
  branch="${spec##*:}"
  if [[ -d "$DEST/$name/.git" ]]; then
    git -C "$DEST/$name" pull --quiet --ff-only
  else
    git clone --quiet --depth 1 --branch "$branch" "https://github.com/AMWA-TV/$name.git" "$DEST/$name"
  fi
  printf '%-28s %-8s %s\n' "$name" "$branch" "$(git -C "$DEST/$name" log -1 --format='%h %cs')"
done
