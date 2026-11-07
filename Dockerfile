FROM ubuntu:26.04

# Bumping one of these is how an upgrade ships. Unpinned, the install layer stays
# cached and a rebuild never picks up a new release.
ARG T3CODE_VERSION=0.1.7
ARG CODEX_RELEASE=0.167.0

ENV T3CODE_HOME=/var/t3/home \
    T3CODE_INSTALL_BIN_DIR=/var/t3/bin \
    PATH=/home/t3/.local/bin:/var/t3/bin:$PATH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Agents run whatever they decide on, and the server doesn't remap container root,
# so escaping as root here would mean root on the host. No account on the server
# has this UID, so an escape as this user gets nobody's files either.
RUN useradd --create-home --uid 10001 --shell /bin/bash t3 \
    && install -d -o t3 -g t3 /var/t3 /workspace

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# Codex goes outside ~/.codex so a volume holding the login there can't hide its binaries.
RUN curl -fsSL https://chatgpt.com/codex/install.sh \
    | CODEX_HOME=/opt/codex CODEX_INSTALL_DIR=/usr/local/bin CODEX_NON_INTERACTIVE=1 sh

USER t3

# The volume folders exist here so that new volumes inherit their owner from them.
RUN curl -fsSL https://t3.codes/install.sh | sh \
    && install -d -m 700 "$T3CODE_HOME/userdata" \
    && install -d "$T3CODE_HOME/worktrees" /home/t3/.local/bin

EXPOSE 3773

# A real API route: unknown paths such as /health get the web app's HTML and a 200.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --start-interval=2s \
    CMD [ "curl", "-fsS", "-o", "/dev/null", "http://127.0.0.1:3773/.well-known/t3/environment" ]

ENTRYPOINT [ "/var/t3/bin/t3" ]
# Published ports can't reach the container's loopback, which is t3's default bind.
CMD [ "--host", "0.0.0.0", "--no-browser" ]
