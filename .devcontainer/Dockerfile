FROM mcr.microsoft.com/devcontainers/python

# Work around broken Yarn apt signing metadata in upstream image on Debian trixie.
# Node/Yarn in this devcontainer comes from features (corepack), not this apt repo.
RUN rm -f /etc/apt/sources.list.d/yarn.list /etc/apt/sources.list.d/yarn*.list

# Pre-create .local/share with correct ownership before bind mounts run.
# Docker creates intermediate mount-target directories as root, which blocks
# pipx and other tools that need to write under ~/.local/share/.
RUN mkdir -p /home/vscode/.local/share /home/vscode/.cache \
    && chown vscode:vscode /home/vscode/.local /home/vscode/.local/share /home/vscode/.cache
