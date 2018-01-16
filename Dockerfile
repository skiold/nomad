FROM docker:17.09-dind

LABEL maintainer="DJ Enriquez <denrie.enriquezjr@gmail.com> (@djenriquez)"


ENV GLIBC_VERSION "2.25-r0"
ENV GOSU_VERSION 1.10

# This is the location of the releases.
ENV HASHICORP_RELEASES=https://releases.hashicorp.com

# nomad setup
RUN addgroup nomad && \
    adduser -S -G nomad nomad

RUN set -x && \
    apk --update add --no-cache --virtual .gosu-deps dpkg curl gnupg && \
    curl -L -o /tmp/glibc-${GLIBC_VERSION}.apk https://github.com/andyshinn/alpine-pkg-glibc/releases/download/${GLIBC_VERSION}/glibc-${GLIBC_VERSION}.apk && \
    apk add --allow-untrusted /tmp/glibc-${GLIBC_VERSION}.apk && \
    rm -rf /tmp/glibc-${GLIBC_VERSION}.apk /var/cache/apk/*
RUN set -x && \
    dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')" && \
    curl -L -o /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch" && \
    curl -L -o /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc" && \
    export GNUPGHOME="$(mktemp -d)" && \
    (gpg --keyserver pgp.mit.edu --recv-keys "B42F6819007F00F88E364FD4036A9C25BF357DD4" || \
      gpg --keyserver keyserver.pgp.com --recv-keys "B42F6819007F00F88E364FD4036A9C25BF357DD4" || \
      gpg --keyserver ha.pool.sks-keyservers.net --recv-keys "B42F6819007F00F88E364FD4036A9C25BF357DD4") && \
    gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu && \
    rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc && \
    chmod +x /usr/local/bin/gosu && \
    gosu nobody true && \
    apk del .gosu-deps

ENV NOMAD_VERSION 0.7.1
ENV CONSUL_VERSION=1.0.2

RUN set -x \
  && apk --update add --no-cache --virtual .nomad-deps gnupg curl \
  &&  mkdir -p /tmp/build \
  && cd /tmp/build \
  && curl -L -o nomad_${NOMAD_VERSION}_linux_amd64.zip ${HASHICORP_RELEASES}/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip \
  && curl -L -o nomad_${NOMAD_VERSION}_SHA256SUMS      ${HASHICORP_RELEASES}/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_SHA256SUMS \
  && curl -L -o nomad_${NOMAD_VERSION}_SHA256SUMS.sig  ${HASHICORP_RELEASES}/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_SHA256SUMS.sig \
  && curl -L -o consul_${CONSUL_VERSION}_linux_amd64.zip ${HASHICORP_RELEASES}/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_amd64.zip \
  && curl -L -o consul_${CONSUL_VERSION}_SHA256SUMS ${HASHICORP_RELEASES}/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_SHA256SUMS \
  && curl -L -o consul_${CONSUL_VERSION}_SHA256SUMS.sig ${HASHICORP_RELEASES}/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_SHA256SUMS.sig  \
  && export GNUPGHOME="$(mktemp -d)" \
  && (gpg --keyserver pgp.mit.edu --recv-keys "91A6E7F85D05C65630BEF18951852D87348FFC4C" || \
      gpg --keyserver keyserver.pgp.com --recv-keys "91A6E7F85D05C65630BEF18951852D87348FFC4C" || \
      gpg --keyserver ha.pool.sks-keyservers.net --recv-keys "91A6E7F85D05C65630BEF18951852D87348FFC4C") \
  && gpg --batch --verify nomad_${NOMAD_VERSION}_SHA256SUMS.sig nomad_${NOMAD_VERSION}_SHA256SUMS \
  && grep nomad_${NOMAD_VERSION}_linux_amd64.zip nomad_${NOMAD_VERSION}_SHA256SUMS | sha256sum -c \
  && unzip -d /bin nomad_${NOMAD_VERSION}_linux_amd64.zip \
  && chmod +x /bin/nomad \
  && gpg --batch --verify consul_${CONSUL_VERSION}_SHA256SUMS.sig consul_${CONSUL_VERSION}_SHA256SUMS \
  && grep consul_${CONSUL_VERSION}_linux_amd64.zip consul_${CONSUL_VERSION}_SHA256SUMS | sha256sum -c \
  && unzip -d /bin consul_${CONSUL_VERSION}_linux_amd64.zip \
  && cd /tmp \
  && rm -rf "$GNUPGHOME" /tmp/build \
  && apk del .nomad-deps

RUN mkdir -p /nomad/data && \
    mkdir -p /etc/nomad && \
    chown -R nomad:nomad /nomad

EXPOSE 4646 4647 4648 4648/udp

# consul setup
# This is the release of Consul to pull in.

# Create a consul user and group first so the IDs get set the same way, even as
# the rest of this may change over time.
RUN addgroup consul && \
    adduser -S -G consul consul

# Set up certificates, base tools, and Consul.
RUN apk add --no-cache ca-certificates curl libcap su-exec && \
    apk del gnupg openssl && \
    rm -rf /root/.gnupg

# The /consul/data dir is used by Consul to store state. The agent will be started
# with /consul/config as the configuration directory so you can add additional
# config files in that location.
RUN mkdir -p /consul/data && \
    mkdir -p /consul/config && \
    chown -R consul:consul /consul

# Expose the consul data directory as a volume since there's mutable state in there.
VOLUME /consul/data

# Server RPC is used for communication between Consul clients and servers for internal
# request forwarding.
EXPOSE 8300

# Serf LAN and WAN (WAN is used only by Consul servers) are used for gossip between
# Consul agents. LAN is within the datacenter and WAN is between just the Consul
# servers in all datacenters.
EXPOSE 8301 8301/udp 8302 8302/udp

# HTTP and DNS (both TCP and UDP) are the primary interfaces that applications
# use to interact with Consul.
EXPOSE 8500 8600 8600/udp

# Consul doesn't need root privileges so we run it as the consul user from the
# entry point script. The entry point script also uses dumb-init as the top-level
# process to reap any zombie processes created by Consul sub-processes.
COPY consul-start.sh /usr/local/bin/consul-start.sh
COPY nomad-start.sh /usr/local/bin/nomad-start.sh

# Install entrykit
RUN set -x && \
    apk --update add --no-cache --virtual .entrykit-deps curl ca-certificates tar && \
    curl -L https://github.com/progrium/entrykit/releases/download/v0.4.0/entrykit_0.4.0_Linux_x86_64.tgz | tar zx && \
    chmod +x entrykit && \
    mv entrykit /bin/entrykit && \
    apk del .entrykit-deps && \
    entrykit --symlink

ENTRYPOINT ["codep", \
    "/usr/local/bin/dockerd-entrypoint.sh", \
    "/usr/local/bin/nomad-start.sh agent -dev", \
    "/usr/local/bin/consul-start.sh agent -dev -client 0.0.0.0" ]
