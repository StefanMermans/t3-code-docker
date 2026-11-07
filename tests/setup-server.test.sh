#!/usr/bin/env bash
#
# bin/setup-server needs root and a real deployer account, so it is tested in a
# throwaway container rather than against anything on this machine.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

exec docker run --rm -v "$root:/src:ro" ubuntu:26.04 bash /src/tests/setup-server.inside.sh
