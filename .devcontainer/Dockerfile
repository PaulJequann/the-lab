FROM mcr.microsoft.com/devcontainers/python

# Work around broken Yarn apt signing metadata in upstream image on Debian trixie.
# Node/Yarn in this devcontainer comes from features (corepack), not this apt repo.
RUN rm -f /etc/apt/sources.list.d/yarn.list /etc/apt/sources.list.d/yarn*.list
