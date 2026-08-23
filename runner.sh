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
SSH_KEY=${GITSITE_SSH_KEY:-/etc/gitsite/ssh}
WORK=${GITSITE_WORK:-/work}
CHECKOUT="$WORK/repo"
SITE="$WORK/site"

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

# One build round. Returns non-zero on any failure; the caller keeps the
# previous site in that case.
build_round() {
    cd "$CHECKOUT" || return 1

    git fetch --quiet --depth=1 origin "$REF" || { log "fetch failed"; return 1; }
    git reset --quiet --hard FETCH_HEAD || { log "reset failed"; return 1; }

    [ -f gitsite.toml ] || { log "gitsite.toml missing in $REPO@$REF"; return 1; }

    local build out lfs
    build=$(read_config build) || { log "gitsite.toml: no readable 'build'"; return 1; }
    out=$(read_config out)     || { log "gitsite.toml: no readable 'out'"; return 1; }
    lfs=$(read_config lfs 2>/dev/null) || lfs=false

    # direnv, not `nix develop`: the build commands call bare names that only
    # resolve once .envrc has run uv sync and put .venv/bin on PATH.
    direnv allow . || { log "direnv allow failed"; return 1; }

    # git-lfs comes from the app's own flake, so it is only available once the
    # direnv environment exists — which is why this runs after direnv allow and
    # not as part of the fetch above.
    if [ "$lfs" = "true" ]; then
        direnv exec . git lfs pull || { log "git lfs pull failed"; return 1; }
    fi

    if ! direnv exec . bash -c "$build"; then
        # Known trap: with git-lfs files, nix hashes either the pointer (from
        # the git tree) or the smudged file (from the worktree) depending on how
        # the source was ingested, and aborts on the mismatch. One refresh fixes
        # it; anything else is a real build failure.
        log "build failed — retrying once after refreshing the nix eval cache"
        nix flake metadata --refresh > /dev/null 2>&1
        direnv exec . bash -c "$build" || { log "build failed"; return 1; }
    fi

    [ -d "$CHECKOUT/$out" ] || { log "build produced no '$out' directory"; return 1; }

    # Atomic swap, never a build in place: a visitor must not be able to see a
    # half-written directory.
    rm -rf "$SITE.new" "$SITE.old"
    cp -r "$CHECKOUT/$out" "$SITE.new" || { log "copy failed"; return 1; }
    [ -e "$SITE" ] && mv "$SITE" "$SITE.old"
    mv "$SITE.new" "$SITE" || { log "swap failed"; return 1; }
    rm -rf "$SITE.old"
    return 0
}

# ----------------------------------------------------------------------- loop

main() {
    setup
    local last_built="" remote
    while true; do
        # ls-remote rather than fetch: a round that finds nothing new costs one
        # network call, so the interval can be short without being expensive.
        remote=$(git -C "$CHECKOUT" ls-remote origin "$REF" 2>/dev/null | cut -f1)
        if [ -z "$remote" ]; then
            log "cannot reach $REPO — retrying in ${INTERVAL}s"
        elif [ "$remote" = "$last_built" ]; then
            :
        else
            log "building $remote"
            if build_round; then
                last_built=$remote
                log "published $remote"
            else
                log "keeping the previous site"
            fi
        fi
        sleep "$INTERVAL"
    done
}

# Only run when executed, so the tests can source this file and call the
# functions one at a time.
[ "${BASH_SOURCE[0]}" = "${0}" ] && main "$@"
