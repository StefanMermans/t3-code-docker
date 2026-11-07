#!/usr/bin/env bash
#
# Boots the real image at the previous release, upgrades it in place, and checks
# nothing was lost. This is the failure a volume on all of /var/t3/home causes:
# t3 itself lives under runtime/ there, so the old copy in the volume hides the
# new one and the container dies with "t3: not found".
set -euo pipefail

readonly PREVIOUS_VERSION=0.1.6
readonly TEST_PORT=37730
readonly CONTAINER_UID=10001

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=SCRIPTDIR/lib.sh
source "$root/tests/lib.sh"

compose() {
    docker compose -p t3-code-test -f "$root/compose.yml" -f "$root/tests/compose.test.yml" "$@"
}

in_container() { compose exec -T t3 "$@"; }

running_version() { in_container t3 --version; }

health() { docker inspect -f '{{.State.Health.Status}}' t3-code-test; }

container_status() { docker inspect -f '{{.State.Status}}' t3-code-test; }

started_at() { docker inspect -f '{{.State.StartedAt}}' t3-code-test; }

environment_json() { curl -fsS "http://127.0.0.1:$TEST_PORT/.well-known/t3/environment"; }

session_json() { curl -fsS "$@" "http://127.0.0.1:$TEST_PORT/api/auth/session"; }

pinned_version=$(sed -n 's/^ARG T3CODE_VERSION=//p' "$root/Dockerfile")
pinned_codex=$(sed -n 's/^ARG CODEX_RELEASE=//p' "$root/Dockerfile")

cleanup() { compose down --volumes --rmi local >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

echo "published port"
host_ips=$(docker compose -f "$root/compose.yml" config --format json | jq -c '[.services[].ports[]?.host_ip]')
assert_eq "compose.yml publishes on loopback and nowhere else" '["127.0.0.1"]' "$host_ips"

# --pull on every build, as bin/deploy does. On Docker's classic image store, going
# from a plain build to a --pull build changes the image ID once, which recreates
# the container and says nothing about a real deploy.
echo "first deploy, at $PREVIOUS_VERSION"
compose build --quiet --pull --build-arg "T3CODE_VERSION=$PREVIOUS_VERSION"
compose up -d --wait --wait-timeout 120
assert_eq "turns healthy" healthy "$(health)"
assert_eq "runs the previous release" "t3 v$PREVIOUS_VERSION" "$(running_version)"

echo "runs unprivileged"
assert_eq "exec uses the t3 user" "$CONTAINER_UID" "$(in_container id -u)"
assert_eq "the server uses the t3 user" "$CONTAINER_UID" "$(in_container stat -c %u /proc/1)"
assert_eq "HOME is the folder on the volume, so logins are kept" /home/t3 "$(in_container printenv HOME)"
assert_succeeds "privileges can't be regained" in_container grep -q 'NoNewPrivs:.*1' /proc/1/status
assert_fails "there is no sudo" in_container sh -c 'command -v sudo'
assert_contains "system packages can't be installed" "$(in_container apt-get install -y jq 2>&1 || true)" "are you root"

environment_before=$(environment_json | sed -E 's/.*"environmentId":"([^"]+)".*/\1/')
session_token=$(in_container t3 auth session issue --token-only --ttl 1h --label upgrade-test)
in_container sh -c '
    touch /home/t3/.marker /workspace/marker /var/t3/home/worktrees/marker
    printf "#!/bin/sh\necho kept\n" > /home/t3/.local/bin/user-tool
    chmod +x /home/t3/.local/bin/user-tool
'

echo "upgrade to $pinned_version"
compose build --quiet --pull
compose up -d --wait --wait-timeout 120
assert_eq "turns healthy again" healthy "$(health)"
assert_eq "runs the pinned release" "t3 v$pinned_version" "$(running_version)"
assert_contains "runs the pinned codex" "$(in_container codex --version)" "$pinned_codex"

echo "state survives"
assert_contains "environment id is unchanged" "$(environment_json)" "\"environmentId\":\"$environment_before\""
assert_contains "apps see a stable name, not a container ID" "$(environment_json)" '"label":"stefanserver"'
assert_eq "usage identity is unchanged" stefanserver "$(in_container cat /var/t3/home/usage-host-id)"
assert_contains "paired sessions still work" \
    "$(session_json -H "Authorization: Bearer $session_token")" '"authenticated":true'
assert_contains "anonymous requests are still refused" "$(session_json)" '"authenticated":false'
assert_succeeds "home is kept" in_container test -e /home/t3/.marker
assert_eq "tools in ~/.local/bin are kept and on PATH" kept "$(in_container user-tool)"
assert_succeeds "workspace is kept" in_container test -e /workspace/marker
assert_succeeds "worktrees are kept" in_container test -e /var/t3/home/worktrees/marker

echo "a deploy that changes nothing"
started_before=$(started_at)
compose build --quiet --pull
compose up -d --wait --wait-timeout 120 --remove-orphans
assert_eq "does not restart the container" "$started_before" "$(started_at)"

echo "agent tooling"
assert_succeeds "git and ssh are installed" in_container sh -c 'command -v git && command -v ssh'
assert_eq "agents start in the workspace" /workspace "$(in_container pwd)"
assert_succeeds "git works in the workspace" in_container git init -q /workspace/repo

echo "installing a system package as root, the way the README describes"
assert_succeeds "root can install it" compose exec -T -u root t3 sh -c \
    'apt-get update -qq && apt-get install -y -qq --no-install-recommends jq'
assert_succeeds "the t3 user can use it" in_container jq --version
compose up -d --wait --wait-timeout 120 --force-recreate
assert_fails "it is gone once the container is replaced" in_container sh -c 'command -v jq'

# Against real Compose, because the deploy's only failure signal is this exit code
# and the README describes what these two cases leave behind.
echo "a new container that runs but never passes its health check"
assert_fails "fails up --wait" compose -f "$root/tests/compose.unhealthy.yml" up -d --wait --wait-timeout 5
assert_eq "is left running" running "$(container_status)"
assert_succeeds "and still answers" environment_json

echo "a new container that crashes on start"
assert_fails "fails up --wait" compose -f "$root/tests/compose.crashing.yml" up -d --wait --wait-timeout 30
assert_fails "and answers nothing" environment_json

finish
