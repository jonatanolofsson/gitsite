# Reference deployment

gitsite builds; something else serves. This directory is that something else —
the arrangement we actually run, so the next site does not have to reinvent it.

| File | What it is |
|---|---|
| [`deployment.yaml`](deployment.yaml) | PVC, ConfigMaps, Deployment and Service for one site |
| [`nginx.conf`](nginx.conf) | the server block the web container mounts |

It is a reference, not a module: copy it, substitute `SITE` and `REPO`, and
add whatever ingress you use. There is no kustomize base here on purpose —
a base that has to be parameterised for every field is harder to read than the
file it generates.

## Substitute two things

- `SITE` — a short name for this site. It becomes the resource names, the
  selector labels, and the key looked up in the `gitsite-deploykeys` secret.
- `REPO` — the app repo to follow. The build command, output directory and
  git-lfs flag are **not** here; they live in that repo's own `gitsite.toml`.

You also need a `gitsite-deploykeys` secret holding one read-only deploy key
per site, under the key named by `SITE`. It is not in this directory because a
secret does not belong in git in plaintext — seal it, or create it out of band.

## What is load-bearing, and why

Four things in `deployment.yaml` look like detail and are not. Each was a bug
first.

**nginx serves by path, not by a mount of `site/`.** The runner publishes with
an atomic `mv`, which replaces the directory's inode. A `subPath` mount of
`/work/site` keeps pointing at the original inode and serves the first build
forever. Mount the parent; let nginx resolve the path per request.

**The init container merges the nix store, it does not seed it.** `cp -a -n`,
not `[ -d /mnt/nix/store ] || cp -a`. The image's `$HOME/.nix-profile` is in
the container layer but symlinks into `/nix`; a copy that only runs on an empty
volume pins the store to whichever image came first, and the next image gets a
profile of links pointing nowhere — `direnv: command not found`, every build,
on every site.

**`HOME` and `TMPDIR` are on the volume.** `HOME` because otherwise nix, uv and
direnv refetch every dependency on every restart. `TMPDIR` because nix builds
the dev shell there, and on the node's ephemeral storage it will eventually
fill the disk.

**The deploy key is mounted in the builder only.** The builder runs the app
repo's build command as written — arbitrary code, by design. The web container
is the one on the network, and it has a read-only mount and no key.

## When one nginx is not enough

The `gitsite-nginx` ConfigMap is shared by every site that only needs static
files. A site that needs more gets its own ConfigMap and points the `nginx`
volume at it. That is the escape hatch that keeps serving out of the builder
image: one of our sites proxies a `/refresh` endpoint to a third container in
the same pod, which no static file server would have done.

```nginx
location /refresh {
    proxy_pass http://127.0.0.1:8090;
}
```

## Checking on it

`kubectl logs deploy/gitsite-<site>` gives you nginx. The builder is the
interesting one:

```bash
kubectl logs deploy/gitsite-<site> -c builder
```

The health of the build is in `$GITSITE_WORK/status.json`, which is outside the
served directory and therefore not reachable over HTTP:

```bash
kubectl exec deploy/gitsite-<site> -c builder -- cat /work/status.json
```

See the top-level [README](../README.md#seeing-whether-it-is-well) for what the
fields mean and what to alarm on.
