FROM alpine:20260805@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000

RUN apk add --no-cache \
      iproute2=7.1.0-r0 \
      openssh-client-common=10.5_p1-r1 \
      openssh-server-pam=10.5_p1-r1 \
      openssh-sftp-server=10.5_p1-r1

COPY sshd-common/entrypoint.sh /usr/local/bin/fixture-entrypoint
COPY sshd-common/netem-profile.sh /usr/local/bin/netem-profile
COPY sshd-common/config/ /etc/ssh/fixture/

RUN chmod 0755 \
      /usr/local/bin/fixture-entrypoint \
      /usr/local/bin/netem-profile

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/fixture-entrypoint"]
