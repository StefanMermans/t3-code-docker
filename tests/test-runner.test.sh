#!/usr/bin/env bash
#
# bin/test has to fail when any test fails, not only the last one.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=SCRIPTDIR/lib.sh
source "$root/tests/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir "$work/fake-bin"
cat > "$work/fake-bin/shellcheck" <<'EOF'
#!/bin/sh
echo "shellcheck ran"
exit "${SHELLCHECK_STATUS:-0}"
EOF
chmod +x "$work/fake-bin/shellcheck"
export PATH="$work/fake-bin:$PATH"

# Copies bin/test into a project of its own, so it runs these fixtures and not
# the real tests.
new_project() {
    project=$(mktemp -d "$work/project.XXXXXX")
    mkdir "$project/bin" "$project/tests"
    cp "$root/bin/test" "$project/bin/test"
    unset SHELLCHECK_STATUS
}

add_test() {
    local name=$1 exit_status=$2
    printf '#!/bin/sh\necho "%s ran"\nexit %s\n' "$name" "$exit_status" > "$project/tests/$name.test.sh"
    chmod +x "$project/tests/$name.test.sh"
}

# Sets output and status.
run_tests() {
    status=0
    output=$("$project/bin/test" 2>&1) || status=$?
}

echo "everything passes"
new_project
add_test first 0
add_test second 0
run_tests
assert_eq "exits 0" 0 "$status"
assert_contains "runs shellcheck" "$output" "shellcheck ran"
assert_contains "runs the first test" "$output" "first ran"
assert_contains "runs the second test" "$output" "second ran"

echo "a failing test followed by a passing one"
new_project
add_test first 1
add_test second 0
run_tests
assert_eq "exits 1" 1 "$status"
assert_not_contains "stops at the failure" "$output" "second ran"

echo "the last test fails"
new_project
add_test first 0
add_test second 1
run_tests
assert_eq "exits 1" 1 "$status"

echo "shellcheck fails"
new_project
add_test first 0
export SHELLCHECK_STATUS=1
run_tests
assert_eq "exits 1" 1 "$status"
assert_not_contains "does not go on to the tests" "$output" "first ran"

echo "works from any directory"
new_project
add_test first 0
status=0
output=$(cd / && "$project/bin/test" 2>&1) || status=$?
assert_eq "exits 0" 0 "$status"
assert_contains "finds the tests" "$output" "first ran"

finish
