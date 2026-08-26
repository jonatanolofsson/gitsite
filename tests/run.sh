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
         # NARHASH_ONCE=1: fail the first invocation the way nix does, so the
         # retry path can be exercised.
         if [ "${NARHASH_ONCE:-0}" = "1" ] && [ ! -e "$SB/narhash-seen" ]; then
             touch "$SB/narhash-seen"
             echo "error: mismatch in field 'narHash' of input"
             exit 1
         fi
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
    export SB
    chmod +x "$SB/bin"/*
    PATH="$SB/bin:$PATH"
    # shellcheck disable=SC1090
    source "$RUNNER"
}

teardown() { rm -rf "$SB"; unset BUILD_EXIT FETCH_EXIT LFS_EXIT BUILD_SIDE_EFFECT NARHASH_ONCE; }

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

# build_round has eight paths to `return 1`. Asserting only the return code
# therefore proves nothing about WHICH check fired — four of the original five
# `out` tests passed with the guard deleted, for unrelated reasons. Assert the
# log line too.
fails_with() { # beskrivning mönster
    local out rc
    out=$(build_round 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
        nope "$1" "build_round lyckades, väntade fel"
    elif printf '%s' "$out" | grep -q "$2"; then
        ok "$1"
    else
        nope "$1" "fel orsak; väntade /$2/, fick: $(printf '%s' "$out" | tail -1)"
    fi
}

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
check "creates HOME" "$([ -d "$HOME" ] && echo yes || echo no)" "yes"
teardown

# --------------------------------------------------------------------------
# Regression: the pod points TMPDIR at the volume so builds do not consume
# ephemeral storage. setup() used not to create it, and nix then failed to
# evaluate the dev shell — after which direnv fell back to an environment
# without the app's toolchain and every build died on a missing `uv`.
sandbox
export TMPDIR="$GITSITE_WORK/tmp"
setup > /dev/null 2>&1
check "creates TMPDIR" "$([ -d "$TMPDIR" ] && echo yes || echo no)" "yes"
unset TMPDIR
teardown

# --------------------------------------------------------------------------
sandbox
given_published_site
setup > /dev/null 2>&1
check "does not overwrite an existing site with the placeholder" \
    "$(site_says)" "<h1>previous</h1>"
teardown

# --------------------------------------------------------------------------
# Regression: a repo with git-lfs files makes nix abort with a narHash
# mismatch. The retry used to wrap only the build — but the FIRST thing to
# enter the environment is `git lfs pull`, so it never fired where the failure
# actually happens. run_in_env now wraps both.
sandbox
given_repo produces_output out true
export NARHASH_ONCE=1
build_round > /dev/null 2>&1
check "recovers from a narHash mismatch on the lfs step" "$?" "0"
check "and publishes the build after the retry" "$(site_says)" "<h1>new</h1>"
teardown

# --------------------------------------------------------------------------
# `out` comes from a file in another repo, and the guard is what stops it
# publishing .git — the source repo's entire history. Every case here asserts
# the guard's own message, so the test fails if the guard is removed.
for bad in "." "./" ".//" "./." ".." "/etc" "../escape" "sub/../.." ""; do
    sandbox
    given_published_site
    printf 'build = "just build"\nout = "%s"\nlfs = false\n' "$bad" \
        > "$GITSITE_WORK/repo/gitsite.toml"
    mkdir -p "$GITSITE_WORK/repo/sub"
    fails_with "rejects out = '$bad'" "must be a directory inside the repo"
    check "  and keeps the previous site" "$(site_says)" "<h1>previous</h1>"
    teardown
done

# .git is inside the repo, so the path check alone lets it through.
for bad in ".git" "sub/../.git"; do
    sandbox
    given_published_site
    printf 'build = "just build"\nout = "%s"\nlfs = false\n' "$bad" \
        > "$GITSITE_WORK/repo/gitsite.toml"
    mkdir -p "$GITSITE_WORK/repo/.git" "$GITSITE_WORK/repo/sub"
    fails_with "rejects out = '$bad'" "must not publish .git"
    teardown
done

# A symlink pointing out of the output directory passed every string check:
# [ -d ] follows it and `cp -r` copied the LINK, making the published directory
# a symlink to the whole workspace.
sandbox
given_published_site
printf 'build = "just build"\nout = "public"\nlfs = false\n' \
    > "$GITSITE_WORK/repo/gitsite.toml"
ln -s . "$GITSITE_WORK/repo/public"
fails_with "rejects out = symlink to the checkout" "must be a directory inside the repo"
teardown

# ...and a dotted name that merely LOOKS like .git must still be allowed.
for good in "site/.github" "public"; do
    sandbox
    printf 'build = "just build"\nout = "%s"\nlfs = false\n' "$good" \
        > "$GITSITE_WORK/repo/gitsite.toml"
    mkdir -p "$GITSITE_WORK/repo/$good"
    echo "<h1>new</h1>" > "$GITSITE_WORK/repo/$good/index.html"
    build_round > /dev/null 2>&1
    check "accepts out = '$good'" "$(site_says)" "<h1>new</h1>"
    teardown
done

# The published directory must never itself be a symlink, whatever out was.
sandbox
given_repo produces_output out
build_round > /dev/null 2>&1
check "publishes a real directory, not a link" \
    "$([ -L "$GITSITE_WORK/site" ] && echo link || echo dir)" "dir"
teardown

echo
printf '%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
