# gitsite builder image.
#
# Carries only what is needed to enter an app repo's own nix dev shell: nix,
# direnv, git, git-lfs, python3. Everything else — the toolchain, the language
# runtimes, the build tool — comes from the app's flake.nix at runtime, which
# is what makes one image serve every site.
FROM debian:bookworm-slim

# uid 1000 owns /nix from the start. The alternative — installing nix as root
# and fixing ownership later — is what forces a privileged pod; this way the
# container satisfies PodSecurity "restricted" without any escalation.
ARG UID=1000
ARG GID=1000

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils git git-lfs python3 openssh-client bash; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd -g "$GID" gitsite; \
    useradd -u "$UID" -g "$GID" -m -s /bin/bash gitsite; \
    mkdir -p /nix; \
    chown "$UID:$GID" /nix

USER $UID:$GID
ENV HOME=/home/gitsite
ENV USER=gitsite

# Both pins matter, and for the same reason: /nix lives on a PVC that outlives
# the image. An unpinned installer or an unpinned nixpkgs gives every rebuild
# DIFFERENT store paths, while $HOME/.nix-profile — which is baked into the
# image layer and on PATH — symlinks into that store. Roll the image onto a
# volume seeded from an older one and the profile dangles: "direnv: command not
# found", every build, on every site. That is exactly what happened.
#
# The initContainer now merges instead of seeding once, so drift no longer
# breaks anything. Pinning is the other half: without it every image rebuild
# adds a whole new closure to the volume that nothing ever collects.
#
# NIXPKGS_REV tracks flake.lock — same source for the image's direnv as for the
# dev shell. Bump both together.
ARG NIX_VERSION=2.35.2
ARG NIXPKGS_REV=cd648d6ea62bc0ffba91e61fcfe5e33c1e2004b1

# Single-user nix: no daemon, no channels. --no-daemon is what allows a
# rootless install into a directory this user already owns.
RUN set -eux; \
    curl -fsSL "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install" \
        | sh -s -- --no-daemon --no-channel-add; \
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"; \
    nix --extra-experimental-features 'nix-command flakes' \
        profile install "github:nixos/nixpkgs/${NIXPKGS_REV}#direnv"; \
    nix-collect-garbage -d

ENV PATH=/home/gitsite/.nix-profile/bin:/home/gitsite/.local/bin:/usr/local/bin:/usr/bin:/bin
ENV NIX_CONFIG="experimental-features = nix-command flakes"

COPY --chown=$UID:$GID runner.sh /usr/local/bin/gitsite-runner
RUN chmod 0755 /usr/local/bin/gitsite-runner

# /nix is copied out of the image into a PVC by an initContainer on first
# start, so the store survives restarts instead of being refetched.
VOLUME ["/work"]

ENTRYPOINT ["/usr/local/bin/gitsite-runner"]
