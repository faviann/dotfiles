FROM node:22-bookworm

# Install system dependencies
RUN apt-get update && apt-get install -y \
  git \
  curl \
  jq \
  xz-utils \
  && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && apt-get update && apt-get install -y gh \
  && rm -rf /var/lib/apt/lists/*

# Build-args for UID/GID alignment: sandcastle docker build-image
# defaults these to the host user's UID/GID so image-built files
# and bind-mounted files share an owner without runtime chown.
ARG AGENT_UID=1000
ARG AGENT_GID=1000

# Rename the base image's "node" user to "agent" and align UID/GID.
RUN groupmod -o -g $AGENT_GID node && usermod -o -u $AGENT_UID -g $AGENT_GID -d /home/agent -m -l agent node

# The repository's validation contract uses Nix flakes. Keep the store local to
# the outer sandbox and writable by the unprivileged agent; no daemon or host
# Nix mount is required.
RUN mkdir -p /etc/nix /nix \
  && printf '%s\n' \
    'experimental-features = nix-command flakes' \
    'sandbox = false' \
    > /etc/nix/nix.conf \
  && chown -R $AGENT_UID:$AGENT_GID /nix

ENV NIX_REMOTE=local
ENV NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# Install Codex CLI (run as root before USER agent)
RUN npm install -g @openai/codex

USER ${AGENT_UID}:${AGENT_GID}

ENV HOME=/home/agent
ENV USER=agent

# Pin the upstream single-user Nix distribution and verify it before install.
ARG NIX_VERSION=2.28.5
ARG NIX_SHA256=2b7e9fda8e17e2143c302a700908e86698c265b5862fc7e6b805942aceef6668
RUN curl -fsSL \
    "https://releases.nixos.org/nix/nix-${NIX_VERSION}/nix-${NIX_VERSION}-x86_64-linux.tar.xz" \
    -o /tmp/nix.tar.xz \
  && printf '%s  %s\n' "$NIX_SHA256" /tmp/nix.tar.xz | sha256sum -c - \
  && tar -xJf /tmp/nix.tar.xz -C /tmp \
  && "/tmp/nix-${NIX_VERSION}-x86_64-linux/install" --no-daemon --yes \
  && rm -rf /tmp/nix.tar.xz "/tmp/nix-${NIX_VERSION}-x86_64-linux"

ENV PATH=/home/agent/.nix-profile/bin:${PATH}

WORKDIR /home/agent

# In worktree sandbox mode, Sandcastle bind-mounts the git worktree at /home/agent/workspace
# and overrides the working directory to /home/agent/workspace at container start.
# Structure your Dockerfile so that /home/agent/workspace can serve as the project root.
ENTRYPOINT ["sleep", "infinity"]
