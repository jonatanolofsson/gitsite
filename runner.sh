#!/usr/bin/env bash
# gitsite runner — follow a git ref, rebuild on change, serve what is in git.
#
# The container is generic. Everything specific to a site comes from two
# places, and the split is deliberate:
#
#   environment  what the infrastructure owns: which repo, which ref, which
#                deploy key, how often to poll
#   gitsite.toml what the app owns, committed in the app repo: the build
#                command, the output directory, whether git-lfs is needed
#
# The app owns its build command because the person who changes the output
# directory changes it in the same commit that causes the change.
set -uo pipefail

REPO=${GITSITE_REPO:?GITSITE_REPO is required}
REF=${GITSITE_REF:-main}
INTERVAL=${GITSITE_INTERVAL:-120}
# SIGHUP means "a push is on its way". See poke() for why it opens a window
# rather than triggering one immediate poll.
EAGER_INTERVAL=${GITSITE_EAGER_INTERVAL:-5}
EAGER_WINDOW=${GITSITE_EAGER_WINDOW:-120}
SSH_KEY=${GITSITE_SSH_KEY:-/etc/gitsite/ssh}
WORK=${GITSITE_WORK:-/work}
CHECKOUT="$WORK/repo"
SITE="$WORK/site"
# Deliberately NOT inside $SITE: the swap replaces that directory wholesale, and
# anything in there is public. Status is for the operator, not the visitor.
STATUS="$WORK/status.json"

# Globals rather than locals in main(): write_status reads them, and the
# alternative is threading two more arguments through every call site.
LAST_BUILT=""
LAST_SUCCESS=""
EAGER_UNTIL=0

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "FATAL: $*"; exit 1; }

# --------------------------------------------------------------- one-time setup

setup() {
    # TMPDIR too, and before anything else: nix builds the dev shell there, and
    # a missing directory fails as "creating directory ...: No such file or
    # directory" — after which direnv silently falls back to an environment
    # without the app's toolchain, and the build dies on a missing `uv`. The
    # pod sets TMPDIR onto the volume so builds do not eat ephemeral storage.
    mkdir -p "$WORK" "${HOME:?HOME is required}" "${TMPDIR:-$WORK/tmp}" ||
        die "cannot write to $WORK"

    if [ -r "$SSH_KEY" ]; then
        export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    else
        log "no deploy key at $SSH_KEY — assuming an anonymous remote"
    fi

    # Serve something from the first second. Without this nginx returns 403 on
    # an empty directory for the 10-20 minutes the first build can take, which
    # reads as a broken deployment rather than a working one that is busy.
    if [ ! -e "$SITE/index.html" ]; then
        mkdir -p "$SITE"
        cat > "$SITE/index.html" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>Bygger…</title>
<style>body{font:16px/1.6 system-ui,sans-serif;margin:15vh auto;max-width:32rem;padding:0 1.5rem;color:#26292e}</style>
<h1>Bygger sajten</h1>
<p>Första bygget tar en stund — beroenden hämtas och cachas. Sidan
uppdateras av sig själv när den är klar; ladda om då och då.</p>
HTML
    fi

    if [ ! -d "$CHECKOUT/.git" ]; then
        log "cloning $REPO ($REF)"
        rm -rf "$CHECKOUT"
        git clone --quiet --branch "$REF" "$REPO" "$CHECKOUT" ||
            die "clone failed — is the deploy key registered on the repo?"
    fi
}

# ------------------------------------------------------------------ per-round

# Read one key out of gitsite.toml. tomllib rather than grep: the file is the
# app's contract with us, and a half-parsed contract is worse than none.
read_config() {
    local key=$1
    python3 - "$CHECKOUT/gitsite.toml" "$key" <<'PY'
import sys, tomllib
path, key = sys.argv[1], sys.argv[2]
with open(path, "rb") as fh:
    cfg = tomllib.load(fh)
value = cfg[key]
print("true" if value is True else "false" if value is False else value)
PY
}

# Run a command inside the app's direnv environment, retrying once on the
# git-lfs/nix narHash trap.
#
# A repo with git-lfs files has two contents for the same path: the pointer in
# the git tree and the smudged file in the worktree. Nix hashes whichever it
# ingested and aborts when a cached evaluation disagrees. One refresh clears it.
#
# This wraps EVERY direnv call, not just the build: the first thing that enters
# the environment is `git lfs pull`, so guarding only the build meant the retry
# never fired for the failure that actually happens first.
run_in_env() {
    local logf rc
    logf=$(mktemp)
    direnv exec . "$@" 2>&1 | tee "$logf"
    rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ] && grep -q narHash "$logf"; then
        log "narHash mismatch (git-lfs pointer vs smudged file) — refreshing and retrying once"
        nix flake metadata --refresh > /dev/null 2>&1
        direnv exec . "$@"
        rc=$?
    fi
    rm -f "$logf"
    return "$rc"
}

# A machine-readable answer to "is this thing still working?".
#
# The failure this exists for is silent: a build that fails every round keeps
# serving the previous site forever, exactly as designed, and looks perfectly
# healthy from outside. A site can be days stale while returning 200. This file
# is the difference between noticing and not.
#
# It carries no error text on purpose. The reason belongs in the log, which is
# already read by a human when something is wrong; copying build output into a
# status file means whatever the build printed — paths, tokens, someone else's
# error message — ends up somewhere it was never reviewed for.
write_status() { # state attempted_sha consecutive_failures
    local tmp
    tmp=$(mktemp "$WORK/.status.XXXXXX" 2>/dev/null) || return 0
    printf '{"state":"%s","ref":"%s","attempted":"%s","published":"%s","consecutive_failures":%s,"last_attempt":"%s","last_success":"%s"}\n' \
        "$1" "$REF" "$2" "$LAST_BUILT" "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LAST_SUCCESS" > "$tmp"
    mv "$tmp" "$STATUS" || rm -f "$tmp"
}

# One build round. Returns non-zero on any failure; the caller keeps the
# previous site in that case.
build_round() {
    cd "$CHECKOUT" || return 1

    git fetch --quiet --depth=1 origin "$REF" || { log "fetch failed"; return 1; }
    git reset --quiet --hard FETCH_HEAD || { log "reset failed"; return 1; }

    [ -f gitsite.toml ] || { log "gitsite.toml missing in $REPO@$REF"; return 1; }

    local build out lfs out_real checkout_real
    build=$(read_config build) || { log "gitsite.toml: no readable 'build'"; return 1; }
    out=$(read_config out)     || { log "gitsite.toml: no readable 'out'"; return 1; }
    lfs=$(read_config lfs 2>/dev/null) || lfs=false

    # Resolve `out` before trusting it. This runs BEFORE the build: an invalid
    # value used to cost a full build on every poll before being rejected.
    #
    # A string check is not enough, and the previous one was exactly that. It
    # rejected "." but not "./", "./." or ".git"; and a repo committing a
    # symlink `public -> .` passed every test, because `[ -d ]` follows
    # symlinks and `cp -r` then copied the LINK. The published directory became
    # a symlink to the whole workspace, .git included — the precise accident
    # this guard exists to prevent.
    #
    # realpath -m resolves symlinks and .. without requiring the path to exist
    # yet (the build has not run). Requiring it strictly BELOW the checkout
    # rejects "", ".", "./", ".//", "..", absolute paths and symlink escapes in
    # one comparison.
    # Reject an absolute value before joining: "$CHECKOUT/$out" turns "/etc"
    # into "/work/repo//etc", which normalises to a path INSIDE the checkout.
    # It is not an escape, but it silently means something other than it says.
    case "$out" in
        /*) log "gitsite.toml: 'out' must be a directory inside the repo, relative to its root, got '$out'"; return 1 ;;
    esac
    out_real=$(realpath -m "$CHECKOUT/$out") || { log "gitsite.toml: cannot resolve 'out' ($out)"; return 1; }
    checkout_real=$(realpath -m "$CHECKOUT")
    case "$out_real" in
        "$checkout_real"/?*) : ;;
        *) log "gitsite.toml: 'out' must be a directory inside the repo, got '$out'"; return 1 ;;
    esac
    # .git as a path COMPONENT, not as a substring: "site/.github" and
    # "public/.gitkeep" are legitimate output directories.
    case "/${out_real#"$checkout_real"/}/" in
        */.git/*) log "gitsite.toml: 'out' must not publish .git, got '$out'"; return 1 ;;
    esac

    # direnv, not `nix develop`: the build commands call bare names that only
    # resolve once .envrc has run uv sync and put .venv/bin on PATH.
    direnv allow . || { log "direnv allow failed"; return 1; }

    # git-lfs comes from the app's own flake, so it is only available once the
    # direnv environment exists — which is why this runs after direnv allow and
    # not as part of the fetch above.
    if [ "$lfs" = "true" ]; then
        run_in_env git lfs pull || { log "git lfs pull failed"; return 1; }
    fi

    run_in_env bash -c "$build" || { log "build failed"; return 1; }

    [ -d "$out_real" ] || { log "build produced no '$out' directory"; return 1; }

    # Atomic swap, never a build in place: a visitor must not be able to see a
    # half-written directory.
    rm -rf "$SITE.new" "$SITE.old"
    # Copy the CONTENTS, not the directory entry: `cp -r dir target` copies a
    # symlinked dir as a symlink, `cp -r dir/. target/` cannot.
    mkdir -p "$SITE.new" || { log "copy failed"; return 1; }
    cp -r "$out_real/." "$SITE.new/" || { log "copy failed"; return 1; }
    [ -e "$SITE" ] && mv "$SITE" "$SITE.old"
    mv "$SITE.new" "$SITE" || { log "swap failed"; return 1; }
    rm -rf "$SITE.old"
    return 0
}

# --------------------------------------------------------------- the SIGHUP nudge

# A push is coming. Poll fast for a while instead of polling once, right now.
#
# The reason is that git has no post-push hook: the only client-side hook near a
# push is pre-push, which runs BEFORE the objects are transferred. A trigger
# from there that caused one immediate `ls-remote` would usually see the commit
# before the pushed one and do nothing, and the change would then wait out the
# full interval anyway — the trigger would look like it worked while buying
# nothing. Opening a window makes the nudge insensitive to that race: the push
# lands within seconds and the next fast poll takes it.
#
# It stays a hint, never an order. Nothing here can publish anything the normal
# poll would not have published a minute later; if the nudge is lost, the site
# is late, not wrong.
poke() {
    EAGER_UNTIL=$(( $(date +%s) + EAGER_WINDOW ))
    log "poked — polling every ${EAGER_INTERVAL}s for the next ${EAGER_WINDOW}s"
}
trap poke HUP

# Seconds until the next poll.
next_nap() {
    if [ "$(date +%s)" -lt "$EAGER_UNTIL" ]; then
        printf '%s\n' "$EAGER_INTERVAL"
    else
        printf '%s\n' "$INTERVAL"
    fi
}

# A plain `sleep N` cannot be cut short. Bash runs a trap only once the
# foreground command has returned, so a signal arriving during the sleep is
# acted on up to INTERVAL seconds late — which for the default 120 s is most of
# what the nudge was supposed to save. Backgrounding the sleep and waiting on it
# lets the trap run the moment the signal arrives.
#
# It also matters that the trap exists at all: the builder is PID 1 in its
# container, and the kernel does not deliver a signal to PID 1 unless that
# process has installed a handler for it. Without `trap poke HUP` above, a
# SIGHUP would be dropped silently rather than doing something visible.
nap() {
    local secs=$1 pid
    sleep "$secs" &
    pid=$!
    wait "$pid" 2>/dev/null
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 0
}

# ----------------------------------------------------------------------- loop

main() {
    setup
    local remote fails=0
    write_status starting "" 0
    while true; do
        # ls-remote rather than fetch: a round that finds nothing new costs one
        # network call, so the interval can be short without being expensive.
        remote=$(git -C "$CHECKOUT" ls-remote origin "$REF" 2>/dev/null | cut -f1)
        if [ -z "$remote" ]; then
            fails=$((fails + 1))
            log "cannot reach $REPO — retrying in ${INTERVAL}s (failed $fails in a row)"
            write_status unreachable "" "$fails"
        elif [ "$remote" = "$LAST_BUILT" ]; then
            :
        else
            log "building $remote"
            if build_round; then
                LAST_BUILT=$remote
                LAST_SUCCESS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
                fails=0
                # What the window was open for has arrived; close it rather
                # than spend the rest of it polling for nothing.
                EAGER_UNTIL=0
                log "published $remote"
                write_status ok "$remote" 0
            else
                fails=$((fails + 1))
                # The count is the point. One failure is a bad commit and fixes
                # itself; twenty is a broken deployment nobody has looked at.
                log "keeping the previous site (failed $fails in a row)"
                write_status failing "$remote" "$fails"
            fi
        fi
        nap "$(next_nap)"
    done
}

# Only run when executed, so the tests can source this file and call the
# functions one at a time.
[ "${BASH_SOURCE[0]}" = "${0}" ] && main "$@"
