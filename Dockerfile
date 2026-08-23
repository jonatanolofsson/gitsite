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

# Single-user nix: no daemon, no channels. --no-daemon is what allows a
# rootless install into a directory this user already owns.
RUN set -eux; \
    curl -fsSL https://nixos.org/nix/install | sh -s -- --no-daemon --no-channel-add; \
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"; \
    nix --extra-experimental-features 'nix-command flakes' \
        profile install nixpkgs#direnv; \
    nix-collect-garbage -d

ENV PATH=/home/gitsite/.nix-profile/bin:/home/gitsite/.local/bin:/usr/local/bin:/usr/bin:/bin
ENV NIX_CONFIG="experimental-features = nix-command flakes"

COPY --chown=$UID:$GID runner.sh /usr/local/bin/gitsite-runner
RUN chmod 0755 /usr/local/bin/gitsite-runner

# /nix is copied out of the image into a PVC by an initContainer on first
# start, so the store survives restarts instead of being refetched.
VOLUME ["/work"]

ENTRYPOINT ["/usr/local/bin/gitsite-runner"]
