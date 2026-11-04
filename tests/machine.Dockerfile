# One "machine" for tests/e2e.sh: its own Docker daemon (docker:dind) and what
# tunnel.sh needs on a real host (bash, the OpenSSH client), plus "script" to
# answer the questions of an interactive run and httpd (busybox-extras) for a
# web page on the inside network. Commands run as the normal user "tester"
# (uid 1001, in the docker group), like on a real server.
FROM docker:29-dind
RUN apk add --no-cache bash openssh-client util-linux-misc busybox-extras \
    && addgroup -g 1001 tester \
    && adduser -D -u 1001 -G tester -s /bin/bash tester \
    && addgroup tester docker
