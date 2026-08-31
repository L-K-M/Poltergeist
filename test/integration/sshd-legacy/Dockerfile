FROM debian:11.11-slim@sha256:e5b6442dd2e9684cf5e87d8338b5968f3b348636fc0be6d7850a381e3731a2bd

ARG OPENSSH_VERSION=1:8.4p1-5+deb11u7

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      openssh-client=${OPENSSH_VERSION} \
      openssh-server=${OPENSSH_VERSION} \
    && rm -rf /var/lib/apt/lists/*

COPY sshd-common/entrypoint.sh /usr/local/bin/fixture-entrypoint
COPY sshd-common/config/ /etc/ssh/fixture/

RUN chmod 0755 /usr/local/bin/fixture-entrypoint

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/fixture-entrypoint"]
