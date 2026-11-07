#!/usr/bin/env bash
#
# bin/deploy against a real git remote and a fake docker that records its calls.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=SCRIPTDIR/lib.sh
source "$root/tests/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

mkdir "$work/fake-bin"
cat > "$work/fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_CALLS"
if [ -n "${DOCKER_FAILS_ON:-}" ] && [[ "$*" == "$DOCKER_FAILS_ON"* ]]; then
    exit 1
fi
if [[ "$*" == *"--version"* ]]; then
    echo "t3 v9.9.9"
fi
EOF
chmod +x "$work/fake-bin/docker"
export PATH="$work/fake-bin:$PATH"

commit_on_origin() {
    git -C "$seed" add -A
    git -C "$seed" commit -q -m "$1"
    git -C "$seed" push -q origin master
}

# Sets origin, seed (a clone to push from) and app (the server's checkout).
new_fixture() {
    local fixture
    fixture=$(mktemp -d "$work/fixture.XXXXXX")
    origin="$fixture/origin.git"
    seed="$fixture/seed"
    app="$fixture/app"
    export DOCKER_CALLS="$fixture/docker-calls"
    : > "$DOCKER_CALLS"
    unset DOCKER_FAILS_ON

    git init -q --bare -b master "$origin"
    git init -q -b master "$seed"
    git -C "$seed" remote add origin "$origin"
    mkdir "$seed/bin"
    cp "$root/bin/deploy" "$seed/bin/deploy"
    commit_on_origin "first"
    git clone -q "$origin" "$app"
}

# Sets output and status.
run_deploy() {
    status=0
    output=$("$app/bin/deploy" 2>&1) || status=$?
}

# Sets output and status. sshd hands a forced command what the client asked to
# run in this variable, which is how CI names the commit it tested.
run_deploy_as_ci() {
    status=0
    output=$(SSH_ORIGINAL_COMMAND=$1 "$app/bin/deploy" 2>&1) || status=$?
}

origin_tip() { git -C "$origin" rev-parse master; }

docker_calls() { cat "$DOCKER_CALLS"; }

echo "a clean checkout deploys"
new_fixture
touch "$seed/new-file"
commit_on_origin "second"
run_deploy
assert_eq "exits 0" 0 "$status"
assert_eq "checkout reaches origin/master" \
    "$(git -C "$origin" rev-parse master)" "$(git -C "$app" rev-parse HEAD)"
assert_eq "builds, waits for healthy, reports the version" \
    "compose build --pull
compose up -d --wait --wait-timeout 120 --remove-orphans
compose exec -T t3 t3 --version" "$(docker_calls)"
assert_contains "reports what is running" "$output" "running t3 v9.9.9"

echo "a pulled change to the script itself takes effect immediately"
new_fixture
printf '#!/usr/bin/env bash\necho new-deploy-script\n' > "$seed/bin/deploy"
commit_on_origin "new script"
run_deploy
assert_eq "exits 0" 0 "$status"
assert_contains "the new version ran" "$output" "new-deploy-script"
assert_eq "the old version did not carry on" "" "$(docker_calls)"

echo "works when started by a relative path"
new_fixture
status=0
output=$(cd "$app" && ./bin/deploy 2>&1) || status=$?
assert_eq "exits 0" 0 "$status"

echo "CI's tested commit is the tip of master"
new_fixture
touch "$seed/new-file"
commit_on_origin "second"
run_deploy_as_ci "$(origin_tip)"
assert_eq "exits 0" 0 "$status"
assert_eq "checkout reaches the tested commit" "$(origin_tip)" "$(git -C "$app" rev-parse HEAD)"
assert_contains "builds" "$(docker_calls)" "compose build --pull"

echo "the pulled script is still told which commit CI tested"
new_fixture
cat > "$seed/bin/deploy" <<'EOF'
#!/usr/bin/env bash
echo "asked for $SSH_ORIGINAL_COMMAND"
EOF
commit_on_origin "new script"
run_deploy_as_ci "$(origin_tip)"
assert_contains "the new version sees it" "$output" "asked for $(origin_tip)"

echo "master moved on after CI's tested commit"
new_fixture
tested=$(origin_tip)
echo broken > "$seed/Dockerfile"
commit_on_origin "merged while the first commit was being tested"
run_deploy_as_ci "$tested"
assert_eq "exits 0, because the newer run deploys" 0 "$status"
assert_contains "says why" "$output" "superseded"
assert_eq "docker is not touched" "" "$(docker_calls)"
assert_eq "the untested commit is not checked out" "$tested" "$(git -C "$app" rev-parse HEAD)"

echo "refuses anything but a full commit SHA"
new_fixture
tip=$(origin_tip)
bad_requests=(
    'touch pwned'
    "${tip:0:39}"
    "${tip}0"
    "$(printf '%s' "$tip" | tr 'a-f' 'A-F')"
    "$tip; touch pwned"
    "$tip
touch pwned"
)
for request in "${bad_requests[@]}"; do
    run_deploy_as_ci "$request"
    assert_eq "exits 1 for: $request" 1 "$status"
done
assert_contains "says why" "$output" "not a commit SHA"
assert_eq "docker is not touched" "" "$(docker_calls)"
assert_fails "the requested command did not run" test -e "$app/pwned"

echo "refuses commits that exist only on the server"
new_fixture
git -C "$app" commit -q --allow-empty -m "made on the server, never pushed"
run_deploy
assert_eq "exits 1" 1 "$status"
assert_contains "says why" "$output" "not on origin/master"
assert_eq "docker is not touched" "" "$(docker_calls)"

echo "refuses a branch with commits of its own"
new_fixture
git -C "$app" checkout -q -b server-hotfix
git -C "$app" commit -q --allow-empty -m "hotfix"
run_deploy
assert_eq "exits 1" 1 "$status"
assert_eq "docker is not touched" "" "$(docker_calls)"

echo "another branch with nothing of its own still deploys master's tip"
new_fixture
git -C "$app" checkout -q -b elsewhere
touch "$seed/new-file"
commit_on_origin "second"
run_deploy
assert_eq "exits 0" 0 "$status"
assert_eq "checkout reaches the tip" "$(origin_tip)" "$(git -C "$app" rev-parse HEAD)"

echo "an unreachable remote fails the deploy"
new_fixture
git -C "$app" remote set-url origin "$work/does-not-exist.git"
run_deploy
assert_eq "fails" 1 "$([ "$status" -ne 0 ] && echo 1 || echo 0)"
assert_eq "docker is not touched" "" "$(docker_calls)"

echo "refuses a dirty checkout"
new_fixture
touch "$app/edited-on-the-server"
touch "$seed/new-file"
commit_on_origin "second"
run_deploy
assert_eq "exits 1" 1 "$status"
assert_contains "says why" "$output" "working tree is dirty"
assert_eq "docker is not touched" "" "$(docker_calls)"
assert_eq "nothing is pulled" \
    "$(git -C "$origin" rev-parse master~1)" "$(git -C "$app" rev-parse HEAD)"

echo "refuses diverged history"
new_fixture
git -C "$app" commit -q --allow-empty -m "made on the server"
touch "$seed/new-file"
commit_on_origin "second"
run_deploy
assert_eq "fails" 1 "$([ "$status" -ne 0 ] && echo 1 || echo 0)"
assert_eq "docker is not touched" "" "$(docker_calls)"

echo "a failed build leaves the running container alone"
new_fixture
export DOCKER_FAILS_ON="compose build"
run_deploy
assert_eq "fails" 1 "$([ "$status" -ne 0 ] && echo 1 || echo 0)"
assert_not_contains "never reaches up" "$(docker_calls)" "compose up"

echo "an unhealthy container fails the deploy"
new_fixture
export DOCKER_FAILS_ON="compose up"
run_deploy
assert_eq "exits 1" 1 "$status"
assert_contains "says where to look" "$output" "docker logs t3-code"
assert_not_contains "never prints logs, they hold a pairing token" "$(docker_calls)" "logs"

echo "a failed version check fails the deploy"
new_fixture
export DOCKER_FAILS_ON="compose exec"
run_deploy
assert_eq "fails" 1 "$([ "$status" -ne 0 ] && echo 1 || echo 0)"
assert_not_contains "does not report success" "$output" "deployed"

finish
