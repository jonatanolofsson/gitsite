# gitsite

A build container that follows a git repo, rebuilds when something lands and
puts the result in a directory. One image for every site — the difference is
in the configuration.

It replaces the pattern where a site is built as a side effect of the
development environment: there the site dies when the dev pod restarts, it is
only built at pod start, and what gets published is the working tree —
uncommitted and all.

## What it does, and does not do

**gitsite builds. It does not serve.** The container clones, builds and writes
the result to `/work/site`. Exposing that directory over HTTP is a separate
container's job — [`deploy/`](deploy/) is a pod that does it, with the nginx
config we run in production.

That split is deliberate, not an omission, and it is worth stating why, because
everything else in this repo assumes a web server is there — the runner even
writes a placeholder page at startup so that server has something to answer
with:

- **A build is arbitrary code, and the listener should not share a container
  with it.** The build command comes from the app's repo and runs as written, in
  a container that also holds the SSH deploy key. The web container mounts
  `/work` read-only and holds no key.
- **Rolling the builder does not take the site down.** Update the builder image,
  or watch a build fail, and the web container keeps answering.
- **Some sites need a real web server regardless.** One of ours proxies
  `/refresh` to a third container in the same pod. A static server baked into
  this image would have been wrong there and redundant everywhere else.

The cost is real, and worth knowing before you copy the arrangement:
`status.json` (below) cannot be reached over HTTP, only with `kubectl exec`;
and `kubectl logs deploy/gitsite-<site>` gives you nginx rather than the
builder — you want `-c builder`.

It knows nothing about authentication either. What sits in front of the web
server — an identity proxy, basic auth, or nothing — is your choice.

## Prerequisite: the app's repo must have nix and direnv

The build runs as `direnv exec . <build>` in the cloned repo. That assumes the
repo has an `.envrc` and normally a `flake.nix`.

The reason is that build commands in practice call bare command names — `hugo`,
`mkdocs build`, `python -m mysite` — which assume an environment somebody has
already set up. `nix develop -c` is not enough when `.envrc` also does
something (installs Python dependencies, puts `.venv/bin` on PATH); direnv does
all of it.

**A repo without an `.envrc` therefore cannot be built by gitsite today.** If
you want to use it for an ordinary hugo or npm project you need to add an
`.envrc` that sets up the tools, or change the runner so it can skip direnv.
The latter is welcome as a PR.

## The configuration is split

**The infrastructure owns** which repo applies, through environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `GITSITE_REPO` | *(required)* | clone URL, normally SSH with a read-only deploy key |
| `GITSITE_REF` | `main` | the branch that is followed |
| `GITSITE_INTERVAL` | `120` | seconds between polls |
| `GITSITE_SSH_KEY` | `/etc/gitsite/ssh` | the private key; if absent, an anonymous remote is assumed |
| `GITSITE_WORK` | `/work` | the clone and the built site (`$GITSITE_WORK/site`) |
| `HOME` | *(required)* | writable and persistent; direnv, uv and nix cache there |
| `TMPDIR` | `$GITSITE_WORK/tmp` | nix builds the dev shell here; put it on the volume, not in the container |
| `GITSITE_EAGER_INTERVAL` | `5` | poll interval while a nudge is active, see below |
| `GITSITE_EAGER_WINDOW` | `120` | how long a nudge lasts, in seconds |

`HOME` **must** be set and point somewhere writable — the runner aborts
immediately otherwise. The image sets `HOME=/home/gitsite`, which works but
lives in the container's own layer: point it at something persistent, or every
dependency is refetched on every restart.

**The app owns** how it is built, in a `gitsite.toml` at the repo root:

```toml
build = "just build"     # the command that produces the site
out   = "public"         # the directory it puts the result in, relative to the repo root
lfs   = false            # run git lfs pull before the build
```

`out` must point at a directory **below** the repo root. The path is
canonicalised with `realpath` before it is accepted, so `.`, `./`, `..`,
absolute paths and symlinks pointing out of the directory are rejected —
otherwise `out = "."` would have published the whole checkout including `.git`,
and with it the app's entire history. `.git` is rejected separately, as a path
component: `site/.github` is allowed.

The check runs before the build, so a bad value does not cost one build per
poll round. What gets published is the *contents* of the directory, never the
directory entry itself — otherwise a symlinked output directory would have
become a symlink in the served directory.

A symlink *inside* the output directory is carried over as it is. If you want
to stop it being followed, that is for the web server to decide:
`disable_symlinks on;` in nginx.

The build command living in the app is deliberate: whoever changes the output
directory changes the file in the same commit that causes the change. The price
is that a broken build command is only discovered in the container — which is
why a missing or invalid `gitsite.toml` is treated as a build failure, and the
previous site stays up.

## Getting started

```bash
docker run --rm \
  -e GITSITE_REPO=https://github.com/you/your-site.git \
  -e HOME=/work/home \
  -v gitsite-data:/work \
  ghcr.io/jonatanolofsson/gitsite:latest
```

The site ends up in `/work/site`. Point a web server at that directory — **not
at a mount of it**, see below.

The first build takes minutes, not seconds: nix fetches the app's dependencies
and caches them in `HOME` and `/nix`.

On Kubernetes, [`deploy/`](deploy/) is the whole arrangement — builder, web
server, volume and deploy key — with the parts that look like detail and are
not called out in [`deploy/README.md`](deploy/README.md).

## What is guaranteed

- **A failed build never takes the site down.** The previous version stays up
  and the runner tries again next round.
- **An empty poll round costs one network call.** `git ls-remote` is compared
  against the last built commit; only on a difference is anything fetched.
- **There is something in the directory from the first second.** Before the
  first build finishes, a simple "building…" page sits there, so a web server
  does not answer 403 on an empty directory.

## Nudge it when you know something has landed

`SIGHUP` to the builder means *a push is on its way*. The runner then switches
to polling every `GITSITE_EAGER_INTERVAL` seconds for `GITSITE_EAGER_WINDOW`
seconds, and closes the window as soon as something has actually been
published.

```bash
kubectl -n gitsite exec deploy/gitsite-<site> -c builder -- kill -HUP 1
```

**Why a window and not a single poll?** Because git has no post-push hook. The
only client-side hook near a push is `pre-push`, and it runs *before* the
objects have been transferred. A nudge from there that triggered exactly one
`ls-remote` would almost always see the commit before the one being pushed, do
nothing, and leave the change to wait out the whole ordinary interval anyway —
the trigger would look like it worked without buying anything. A window makes
the nudge insensitive to that race: the push lands within seconds and the next
fast round takes it.

The nudge is a hint, never an order. Nothing in it publishes anything the
ordinary poll would not have published a minute later, so a lost nudge makes
the site late — not wrong. A `pre-push` that nudges should therefore never be
able to stop a push.

One detail worth knowing if you change the runner: `sleep N` cannot be cut
short. Bash runs a trap only once the foreground command has returned, so a
signal during an ordinary sleep takes effect up to a whole interval late. The
sleep is therefore run in the background with `wait`. That the trap exists at
all also matters in itself: the builder is PID 1, and the kernel does not
deliver signals to a PID 1 that has no handler.

## Seeing whether it is well

The guarantee above has a flip side: **a build that fails every round is
invisible from outside.** The site answers 200 with last week's content and
looks perfectly healthy. The runner therefore writes
`$GITSITE_WORK/status.json` after every round:

```json
{"state":"failing","ref":"main","attempted":"9f2c…","published":"4a71…",
 "consecutive_failures":7,"last_attempt":"2026-08-26T16:12:04Z",
 "last_success":"2026-08-24T09:31:55Z"}
```

`state` is `ok`, `failing`, `unreachable` or `starting`. The file lies
**outside** the served directory — the swap replaces that directory wholesale,
and the status concerns operations, not the visitor.

It deliberately carries no error text. The reason is in the log, which is read
anyway when something is wrong; copying build output into a status file means
that whatever the build printed — paths, tokens, somebody else's error message
— ends up somewhere it was never reviewed for.

The cheapest alarm is on the log, which prints a counter for exactly this:

```
keeping the previous site (failed 7 in a row)
```

A lone one is a broken commit that fixes itself. A two-digit number is a deploy
nobody has looked at. Alarm on the second, not on the first.

## Known limitations

- **Publishing is not atomic in the strict sense.** The build happens off to
  the side and the directory is swapped with two `mv`s — between them there is
  a brief gap where `site/` does not exist. If the container dies right there,
  the build is left as `site.new` and the next round republishes.
- **Do not mount `site/` directly.** The swap replaces the directory's inode,
  so a bind mount of `site/` specifically keeps pointing at the old one and
  serves the first build forever. Mount the parent and let the web server
  resolve the path per request.
- **The build command comes from the app's repo and is run as written.**
  Whoever can push to the app repo can run arbitrary code in the container.
  That is unavoidable — a build *is* arbitrary code — but it is the reason the
  deploy key should be read-only and per repo, and the container should have no
  other privileges.
- A repo without an `.envrc` is not supported, see above.
- **If you put `/nix` on a volume that outlives the image — merge, do not
  seed.** The image's `$HOME/.nix-profile` lives in the container layer but
  symlinks into `/nix`. If you only copy the store when the volume is empty it
  is stuck at whichever version happened to come first, and a newer image gets
  a profile of links with no targets: `direnv: command not found` on every
  build. `cp -a -n /nix/. <volume>/` adds what is missing without touching what
  is there — safe because store paths are content-addressed and immutable.

## Development

```
just check     # lint + test
just test      # tests only
just lint      # shellcheck
```

The tests run without a framework and stub `git`, `direnv` and `nix`. The
emphasis is on the failure paths: that a broken build keeps the previous site,
that an invalid `gitsite.toml` is not published, and that `out` cannot point
out of the repo.

The tools are declared in `flake.nix` so that `just check` works in every
environment, not only where a python happens to be installed. CI runs exactly
the same `just check` through the same nix shell.

The image pins both the nix version and the nixpkgs revision (`ARG` at the top
of the `Dockerfile`). The revision is the same as `flake.lock` — the image's
direnv and the development shell come out of the same nixpkgs. **Bump them
together**, or the repo says one thing and the image another.

## Licence

MIT, see [LICENSE](LICENSE).
