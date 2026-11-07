# shellcheck shell=bash
# Assertions shared by the test scripts.

failures=0

pass() { printf '  ok    %s\n' "$1"; }

fail() {
    printf '  FAIL  %s\n' "$1" >&2
    failures=$((failures + 1))
}

# Prints expected and actual, so never point this at a secret.
assert_eq() {
    local description=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        pass "$description"
    else
        fail "$description: expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local description=$1 haystack=$2 needle=$3
    case "$haystack" in
        *"$needle"*) pass "$description" ;;
        *) fail "$description: '$needle' not in: $haystack" ;;
    esac
}

assert_not_contains() {
    local description=$1 haystack=$2 needle=$3
    case "$haystack" in
        *"$needle"*) fail "$description: '$needle' found in: $haystack" ;;
        *) pass "$description" ;;
    esac
}

assert_succeeds() {
    local description=$1
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$description"
    else
        fail "$description"
    fi
}

assert_fails() {
    local description=$1
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$description"
    else
        pass "$description"
    fi
}

finish() {
    if [ "$failures" -gt 0 ]; then
        printf '%s failure(s)\n' "$failures" >&2
        exit 1
    fi
    printf 'all passed\n'
}
