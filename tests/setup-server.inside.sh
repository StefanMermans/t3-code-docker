#!/usr/bin/env bash
#
# Runs inside the container started by setup-server.test.sh. Uses a real sshd, so
# the forced command on the CI key is exercised rather than assumed.
set -euo pipefail

# shellcheck source=SCRIPTDIR/lib.sh
source /src/tests/lib.sh

readonly APP_DIR=/var/www/t3-code-docker
readonly SSH_DIR=/home/deployer/.ssh
readonly AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
readonly REPO=/srv/origin.git

# The shapes of real `tailscale status --json` output. A service a client may use
# appears under services/<name> whether or not this machine is approved to host
# it, so only service-host counts.
readonly STATUS_APPROVED='{"Self":{"CapMap":{"service-host":[{"svc:prowlarr":["100.1.1.1"],"svc:t3":["100.1.1.2"]}]}}}'
readonly STATUS_NOT_APPROVED='{"Self":{"CapMap":{"service-host":[{"svc:prowlarr":["100.1.1.1"]}],"services/t3":[{"Name":"svc:t3"}]}}}'
readonly STATUS_NO_CAPABILITIES='{"Self":{"CapMap":null}}'

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends git jq openssh-client openssh-server >/dev/null

# Sets output and status. Starts from a directory deployer can't read, because
# that is what running this from a home directory looks like.
run_setup() {
    status=0
    output=$(cd /root && T3_REPO_URL=${repo_url:-$REPO} bash /src/bin/setup-server "$@" 2>&1) || status=$?
}

count_lines() { grep -cxF -- "$1" "$2" || true; }

owner_and_mode() { stat -c '%U %a' "$1"; }

create_repository() {
    local seed=/tmp/seed
    git init -q --bare -b master "$REPO"
    git init -q -b master "$seed"
    mkdir "$seed/bin"
    cp /src/bin/deploy "$seed/bin/deploy"
    git -C "$seed" add -A
    git -C "$seed" -c user.name=test -c user.email=test@example.com commit -q -m first
    git -C "$seed" push -q "$REPO" master
    chown -R deployer: "$REPO"
}

install_fake_tailscale() {
    cat > /usr/local/bin/tailscale <<'EOF'
#!/bin/sh
case "$1" in
    serve)
        echo "$*" >> /tmp/tailscale-calls
        [ ! -e /tmp/tailscale-should-fail ]
        ;;
    status)
        cat /tmp/tailscale-status
        ;;
esac
EOF
    chmod +x /usr/local/bin/tailscale
}

install_fake_docker() {
    cat > /usr/local/bin/docker <<'EOF'
#!/bin/sh
echo "$*" >> /tmp/docker-calls
EOF
    chmod +x /usr/local/bin/docker
}

set_tailscale_status() { printf '%s' "$1" > /tmp/tailscale-status; }

docker_calls() { cat /tmp/docker-calls 2>/dev/null || true; }

ssh_as_ci() {
    ssh -i /tmp/ci -p 22 -o BatchMode=yes -o HostKeyAlias=homeserver -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$1" deployer@127.0.0.1 "${@:2}"
}

install_fake_tailscale
install_fake_docker
set_tailscale_status "$STATUS_APPROVED"
ssh-keygen -q -t ed25519 -N '' -C ci-key -f /tmp/ci
ci_public_key=$(cat /tmp/ci.pub)
expected_entry="restrict,command=\"$APP_DIR/bin/deploy\" $ci_public_key"

echo "rejects a missing deployer account"
run_setup "$ci_public_key"
assert_eq "exits 1" 1 "$status"
assert_contains "says why" "$output" "user deployer does not exist"

useradd -m -s /bin/bash deployer
# Unlocked for key login, with no usable password.
usermod -p '*' deployer
create_repository

echo "rejects bad arguments"
run_setup
assert_eq "no argument exits 1" 1 "$status"
assert_contains "no argument shows usage" "$output" "usage:"
run_setup "$(cat /tmp/ci)"
assert_eq "a private key exits 1" 1 "$status"
assert_not_contains "a private key is not echoed back" "$output" "PRIVATE KEY"
run_setup "not a key"
assert_eq "garbage exits 1" 1 "$status"
run_setup "$ci_public_key
ssh-ed25519 AAAA smuggled"
assert_eq "a second line exits 1" 1 "$status"
assert_fails "nothing is authorized" test -e "$AUTHORIZED_KEYS"

echo "refuses to run unprivileged"
status=0
output=$(runuser -u deployer -- bash /src/bin/setup-server "$ci_public_key" 2>&1) || status=$?
assert_eq "exits 1" 1 "$status"
assert_contains "says why" "$output" "must run as root"

echo "requires jq"
mv /usr/bin/jq /usr/bin/jq.hidden
run_setup "$ci_public_key"
mv /usr/bin/jq.hidden /usr/bin/jq
assert_eq "exits 1" 1 "$status"
assert_contains "says why" "$output" "jq is required"
assert_fails "changes nothing" test -e "$SSH_DIR"

echo "first run, before GitHub knows the deploy key"
repo_url=/srv/not-readable-yet.git run_setup "$ci_public_key"
assert_eq "exits 1" 1 "$status"
assert_eq "ssh dir belongs to deployer" "deployer 700" "$(owner_and_mode "$SSH_DIR")"
assert_eq "deploy key belongs to deployer" "deployer 600" "$(owner_and_mode "$SSH_DIR/t3-code-docker-github")"
deploy_key_before=$(cat "$SSH_DIR/t3-code-docker-github")
assert_contains "prints the command to add the key" "$output" "gh repo deploy-key add -"
assert_contains "the printed key is the public half" "$output" "$(cat "$SSH_DIR/t3-code-docker-github.pub")"
assert_eq "adds the github alias" 1 "$(count_lines 'Host github.com-t3-code-docker' "$SSH_DIR/config")"
assert_fails "does not clone" test -e "$APP_DIR"
assert_fails "does not authorize CI yet" test -e "$AUTHORIZED_KEYS"
assert_fails "does not publish yet" test -e /tmp/tailscale-calls

echo "second run, with access"
# No trailing newline: appending blindly would corrupt this other app's key.
install -m 600 -o deployer -g deployer /dev/null "$AUTHORIZED_KEYS"
printf 'ssh-ed25519 AAAAexisting speed-dial' > "$AUTHORIZED_KEYS"
run_setup "$ci_public_key"
assert_eq "exits 0" 0 "$status"
assert_contains "says what to do next" "$output" "gh workflow run deploy.yml"
assert_eq "checkout belongs to deployer" deployer "$(stat -c '%U' "$APP_DIR/.git")"
assert_eq "existing key is intact" 1 "$(count_lines 'ssh-ed25519 AAAAexisting speed-dial' "$AUTHORIZED_KEYS")"
assert_eq "CI key is forced to the deploy" 1 "$(count_lines "$expected_entry" "$AUTHORIZED_KEYS")"
assert_eq "publishes on the tailnet" \
    "serve --service=svc:t3 --https=443 http://127.0.0.1:3773" "$(cat /tmp/tailscale-calls)"

echo "third run changes nothing"
run_setup "$ci_public_key"
assert_eq "exits 0" 0 "$status"
assert_eq "CI key is not duplicated" 1 "$(count_lines "$expected_entry" "$AUTHORIZED_KEYS")"
assert_eq "github alias is not duplicated" 1 "$(count_lines 'Host github.com-t3-code-docker' "$SSH_DIR/config")"
assert_eq "deploy key is not replaced" "$deploy_key_before" "$(cat "$SSH_DIR/t3-code-docker-github")"

echo "tailscale serve itself fails"
touch /tmp/tailscale-should-fail
run_setup "$ci_public_key"
rm /tmp/tailscale-should-fail
assert_eq "exits 1" 1 "$status"
assert_contains "says so" "$output" "tailscale serve failed"
assert_not_contains "does not claim to be ready" "$output" "server is ready"

echo "no admin has approved the service"
# tailscale serve exits 0 in this state, and only mentions it in its output.
set_tailscale_status "$STATUS_NOT_APPROVED"
run_setup "$ci_public_key"
assert_eq "exits 1" 1 "$status"
assert_contains "points at the admin console" "$output" "admin console"
assert_not_contains "does not claim to be ready" "$output" "server is ready"

echo "this machine has no service capabilities at all"
set_tailscale_status "$STATUS_NO_CAPABILITIES"
run_setup "$ci_public_key"
assert_eq "exits 1" 1 "$status"
assert_contains "points at the admin console" "$output" "admin console"
set_tailscale_status "$STATUS_APPROVED"

echo "the CI key through a real sshd and the real bin/deploy"
mkdir -p /run/sshd
ssh-keygen -A >/dev/null
/usr/sbin/sshd
printf 'homeserver %s\n' "$(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)" > /tmp/pinned-host
status=0
ssh_as_ci /tmp/pinned-host "$(git -C "$REPO" rev-parse master)" >/dev/null 2>&1 || status=$?
assert_eq "connects with the workflow's flags and deploys" 0 "$status"
assert_contains "the deploy reaches docker" "$(docker_calls)" "compose build --pull"

echo "the CI key can't run anything else"
rm -f /tmp/docker-calls
status=0
ssh_as_ci /tmp/pinned-host 'touch /tmp/pwned' >/dev/null 2>&1 || status=$?
assert_eq "exits 1" 1 "$status"
assert_fails "the requested command did not run" test -e /tmp/pwned
assert_eq "nothing is deployed" "" "$(docker_calls)"

echo "the workflow refuses a server with the wrong host key"
ssh-keygen -q -t ed25519 -N '' -f /tmp/other-host
printf 'homeserver %s\n' "$(cut -d' ' -f1,2 /tmp/other-host.pub)" > /tmp/wrong-host
status=0
ssh_as_ci /tmp/wrong-host "$(git -C "$REPO" rev-parse master)" >/dev/null 2>&1 || status=$?
assert_eq "connection fails" 255 "$status"
assert_eq "nothing is deployed" "" "$(docker_calls)"

finish
