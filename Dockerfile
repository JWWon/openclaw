FROM node:24-trixie

# Install Bun globally (accessible to all users, not just root)
RUN curl -fsSL https://bun.sh/install | bash && \
    mv /root/.bun/bin/bun /usr/local/bin/bun && \
    chmod 755 /usr/local/bin/bun && \
    rm -rf /root/.bun

RUN corepack enable
ENV PNPM_HOME=/home/node/.local/share/pnpm
ENV PATH=/home/node/.local/bin:${PNPM_HOME}:${PATH}
RUN cat >/etc/profile.d/openclaw-cli-paths.sh <<'EOF'
# Keep OpenClaw CLI tool paths available in login shells (including root).
export PNPM_HOME="${PNPM_HOME:-/home/node/.local/share/pnpm}"

case ":$PATH:" in
  *":/home/linuxbrew/.linuxbrew/bin:"*) ;;
  *) PATH="/home/linuxbrew/.linuxbrew/bin:$PATH" ;;
esac

case ":$PATH:" in
  *":/home/linuxbrew/.linuxbrew/sbin:"*) ;;
  *) PATH="/home/linuxbrew/.linuxbrew/sbin:$PATH" ;;
esac

case ":$PATH:" in
  *":/home/node/.local/bin:"*) ;;
  *) PATH="/home/node/.local/bin:$PATH" ;;
esac

case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) PATH="$PNPM_HOME:$PATH" ;;
esac

export PATH
EOF

WORKDIR /app
RUN chown node:node /app

# Install core development tools
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    vim \
    curl \
    gpg \
    ca-certificates \
    && apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install Homebrew (Linuxbrew) and expose brew globally.
ARG OPENCLAW_INSTALL_HOMEBREW="1"
ARG OPENCLAW_BREW_INSTALL_DIR="/home/linuxbrew/.linuxbrew"
ENV HOMEBREW_PREFIX=${OPENCLAW_BREW_INSTALL_DIR}
ENV HOMEBREW_CELLAR=${OPENCLAW_BREW_INSTALL_DIR}/Cellar
ENV HOMEBREW_REPOSITORY=${OPENCLAW_BREW_INSTALL_DIR}/Homebrew
ENV PATH=${OPENCLAW_BREW_INSTALL_DIR}/bin:${OPENCLAW_BREW_INSTALL_DIR}/sbin:${PATH}
RUN if [ -n "$OPENCLAW_INSTALL_HOMEBREW" ]; then \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    file \
    git \
    procps \
    && if ! id -u linuxbrew >/dev/null 2>&1; then useradd -m -s /bin/bash linuxbrew; fi && \
    mkdir -p "${OPENCLAW_BREW_INSTALL_DIR}" && \
    chown -R linuxbrew:linuxbrew "$(dirname "${OPENCLAW_BREW_INSTALL_DIR}")" && \
    su - linuxbrew -c "NONINTERACTIVE=1 CI=1 /bin/bash -c '$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)'" && \
    if [ ! -e "${OPENCLAW_BREW_INSTALL_DIR}/Library" ]; then ln -s "${OPENCLAW_BREW_INSTALL_DIR}/Homebrew/Library" "${OPENCLAW_BREW_INSTALL_DIR}/Library"; fi && \
    if [ ! -x "${OPENCLAW_BREW_INSTALL_DIR}/bin/brew" ]; then echo "brew install failed" && exit 1; fi && \
    chown -R node:node "${OPENCLAW_BREW_INSTALL_DIR}" && \
    ln -sf "${OPENCLAW_BREW_INSTALL_DIR}/bin/brew" /usr/local/bin/brew && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

# Install Claude CLI and expose the command globally.
ARG OPENCLAW_INSTALL_CLAUDE_CLI="1"
ARG OPENCLAW_CLAUDE_CHANNEL="stable"
RUN if [ -n "$OPENCLAW_INSTALL_CLAUDE_CLI" ]; then \
    su - node -c "curl -fsSL https://claude.ai/install.sh | bash -s ${OPENCLAW_CLAUDE_CHANNEL}" && \
    rm -f /usr/local/bin/claude && \
    /home/node/.local/bin/claude --version; \
    fi

# Install GitHub CLI (gh)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
    gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
    tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && \
    apt-get install -y gh && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install uv (Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    mv /root/.local/bin/uv /usr/local/bin/uv && \
    mv /root/.local/bin/uvx /usr/local/bin/uvx && \
    chmod 755 /usr/local/bin/uv /usr/local/bin/uvx && \
    rm -rf /root/.local

# Install Python 3.13 using uv and set as default
RUN uv python install 3.13 && \
    ln -sf /root/.local/share/uv/python/cpython-3.13.*/bin/python3.13 /usr/local/bin/python3 && \
    ln -sf /usr/local/bin/python3 /usr/local/bin/python && \
    chmod 755 /usr/local/bin/python3 /usr/local/bin/python

ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

COPY --chown=node:node package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY --chown=node:node ui/package.json ./ui/package.json
COPY --chown=node:node patches ./patches
COPY --chown=node:node scripts ./scripts

USER node
RUN pnpm install --frozen-lockfile

# Optionally install Chromium and Xvfb for browser automation.
# Build with: docker build --build-arg OPENCLAW_INSTALL_BROWSER=1 ...
# Adds ~300MB but eliminates the 60-90s Playwright install on every container start.
# Must run after pnpm install so playwright-core is available in node_modules.
USER root
ARG OPENCLAW_INSTALL_BROWSER=""
RUN if [ -n "$OPENCLAW_INSTALL_BROWSER" ]; then \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xvfb && \
    node /app/node_modules/playwright-core/cli.js install --with-deps chromium && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

USER node
COPY --chown=node:node . .
RUN npm --prefix vendor/a2ui/renderers/lit ci
RUN pnpm add -D -w rolldown@1.0.0-rc.5
RUN pnpm build
# Force pnpm for UI build (Bun may fail on ARM/Synology architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

ENV NODE_ENV=production

# Security hardening: Run as non-root user
# The node:24-trixie image includes a 'node' user (uid 1000)
# This reduces the attack surface by preventing container escape via root privileges
USER node

# Start gateway server with default config.
# Binds to loopback (127.0.0.1) by default for security.
#
# For container platforms requiring external health checks:
#   1. Set OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD env var
#   2. Override CMD: ["node","openclaw.mjs","gateway","--allow-unconfigured","--bind","lan"]
CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
