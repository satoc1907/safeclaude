FROM node:22-slim

# Install basic tools + unzip (Bun installer needs it)
RUN apt-get update && apt-get install -y \
    git \
    curl \
    vim \
    ripgrep \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Install Bun (required for Claude Code Channels plugins)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:$PATH"

# Create non-root user
RUN useradd -m -s /bin/bash claude

# Create mount points
RUN mkdir -p /host /workspace && chown claude:claude /workspace

USER claude
ENV PATH="/home/claude/.bun/bin:$PATH"

WORKDIR /workspace

ENTRYPOINT ["claude", "--dangerously-skip-permissions", \
            "--channels", "plugin:discord@claude-plugins-official"]