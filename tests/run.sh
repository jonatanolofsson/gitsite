#!/usr/bin/env bash
# Tests for runner.sh. No framework: the thing under test is a shell script,
# and the interesting behaviour is what it does to a directory tree.
#
# The point of these is the failure paths. A runner that publishes a good build
# is easy; one that refuses to replace a working site with a broken one is the
# reason this file exists.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER="$HERE/../runner.sh"
passed=0
failed=0

ok()   { printf '  ok   %s\n' "$1"; passed=$((passed + 1)); }
nope() { printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; failed=$((failed + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else nope "$1" "expected '$3', got '$2'"; fi; }

# A sandbox with stub git/direnv/nix on PATH, a checkout, and the runner
# sourced but not started. Each test gets its own.
sandbox() {
    SB=$(mktemp -d)
    export GITSITE_WORK="$SB/work"
    export HOME="$SB/home"
    export GITSITE_REPO="git@example.invalid:test/repo.git"
    export GITSITE_SSH_KEY="$SB/nonexistent-key"
    mkdir -p "$SB/bin" "$GITSITE_WORK/repo" "$SB/home"

    # Stubs. BUILD_EXIT and FETCH_EXIT let a test choose how they behave.
    cat > "$SB/bin/direnv" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  allow) exit 0 ;;
  exec)  shift 2                       # drop "exec" and the directory
         if [ "$1" = "git" ]; then exit "${LFS_EXIT:-0}"; fi
         if [ "$1" = "bash" ]; then
             [ "${BUILD_EXIT:-0}" = "0" ] || exit "${BUILD_EXIT}"
             eval "${BUILD_SIDE_EFFECT:-true}"
             exit 0
         fi
         exit 0 ;;
esac
STUB
    cat > "$SB/bin/nix" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    cat > "$SB/bin/git" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    fetch)      exit "${FETCH_EXIT:-0}" ;;
    reset)      exit 0 ;;
    ls-remote)  echo -e "${REMOTE_SHA:-abc123}\trefs/heads/main"; exit 0 ;;
    clone)      exit 0 ;;
  esac
done
exit 0
STUB
    chmod +x "$SB/bin"/*
    PATH="$SB/bin:$PATH"
    # shellcheck disable=SC1090
    source "$RUNNER"
}

teardown() { rm -rf "$SB"; unset BUILD_EXIT FETCH_EXIT LFS_EXIT BUILD_SIDE_EFFECT; }

# Write a gitsite.toml and an output directory containing one page.
given_repo() { # build_ok out_dir [lfs]
    printf 'build = "just build"\nout = "%s"\nlfs = %s\n' "$2" "${3:-false}" \
        > "$GITSITE_WORK/repo/gitsite.toml"
    if [ "$1" = "produces_output" ]; then
        mkdir -p "$GITSITE_WORK/repo/$2"
        echo "<h1>new</h1>" > "$GITSITE_WORK/repo/$2/index.html"
    fi
}

given_published_site() {
    mkdir -p "$GITSITE_WORK/site"
    echo "<h1>previous</h1>" > "$GITSITE_WORK/site/index.html"
}

site_says() { cat "$GITSITE_WORK/site/index.html" 2> /dev/null; }

echo "runner.sh"

# --------------------------------------------------------------------------
sandbox
given_repo produces_output out
build_round > /dev/null 2>&1
check "publishes a successful build" "$(site_says)" "<h1>new</h1>"
check "leaves no .new scratch directory" "$([ -e "$GITSITE_WORK/site.new" ] && echo yes || echo no)" "no"
check "leaves no .old scratch directory" "$([ -e "$GITSITE_WORK/site.old" ] && echo yes || echo no)" "no"
teardown

# --------------------------------------------------------------------------
sandbox
given_published_site
given_repo produces_output out
export BUILD_EXIT=1
build_round > /dev/null 2>&1
rc=$?
check "a failing build returns non-zero" "$rc" "1"
check "a failing build keeps the previous site" "$(site_says)" "<h1>previous</h1>"
teardown

# --------------------------------------------------------------------------
sandbox
given_published_site
# no gitsite.toml written at all
build_round > /dev/null 2>&1
check "missing gitsite.toml is a build failure" "$?" "1"
check "missing gitsite.toml keeps the previous site" "$(site_says)" "<h1>previous</h1>"
teardown

# --------------------------------------------------------------------------
sandbox
given_published_site
printf 'out = "out"\n' > "$GITSITE_WORK/repo/gitsite.toml"   # 'build' missing
build_round > /dev/null 2>&1
check "gitsite.toml without 'build' is a failure" "$?" "1"
check "and keeps the previous site" "$(site_says)" "<h1>previous</h1>"
teardown

# --------------------------------------------------------------------------
sandbox
given_published_site
given_repo no_output out          # build "succeeds" but writes nothing
build_round > /dev/null 2>&1
check "a build with no output directory fails" "$?" "1"
check "and keeps the previous site" "$(site_says)" "<h1>previous</h1>"
teardown

# --------------------------------------------------------------------------
sandbox
given_published_site
given_repo produces_output out
export FETCH_EXIT=1
build_round > /dev/null 2>&1
check "a failed fetch is a build failure" "$?" "1"
check "and keeps the previous site" "$(site_says)" "<h1>previous</h1>"
teardown

# --------------------------------------------------------------------------
sandbox
given_repo produces_output site/dist
build_round > /dev/null 2>&1
check "honours a nested out directory" "$(site_says)" "<h1>new</h1>"
teardown

# --------------------------------------------------------------------------
sandbox
given_repo produces_output out true
export LFS_EXIT=1
build_round > /dev/null 2>&1
check "a failed git lfs pull is a build failure" "$?" "1"
teardown

# --------------------------------------------------------------------------
sandbox
given_repo produces_output out
check "reads build from gitsite.toml" "$(read_config build)" "just build"
check "reads out from gitsite.toml" "$(read_config out)" "out"
check "reads lfs as a boolean" "$(read_config lfs)" "false"
teardown

# --------------------------------------------------------------------------
sandbox
setup > /dev/null 2>&1
check "seeds a placeholder page before the first build" \
    "$([ -s "$GITSITE_WORK/site/index.html" ] && echo yes || echo no)" "yes"
teardown

# --------------------------------------------------------------------------
sandbox
given_published_site
setup > /dev/null 2>&1
check "does not overwrite an existing site with the placeholder" \
    "$(site_says)" "<h1>previous</h1>"
teardown

echo
printf '%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
