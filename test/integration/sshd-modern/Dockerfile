FROM alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1

RUN apk add --no-cache \
      iproute2=6.15.0-r0 \
      openssh-client-common=10.0_p1-r10 \
      openssh-server-pam=10.0_p1-r10 \
      openssh-sftp-server=10.0_p1-r10

COPY sshd-common/entrypoint.sh /usr/local/bin/fixture-entrypoint
COPY sshd-common/netem-profile.sh /usr/local/bin/netem-profile
COPY sshd-common/config/ /etc/ssh/fixture/

RUN chmod 0755 \
      /usr/local/bin/fixture-entrypoint \
      /usr/local/bin/netem-profile

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/fixture-entrypoint"]
