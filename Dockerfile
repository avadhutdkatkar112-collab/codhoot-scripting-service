FROM golang:1.22-bookworm@sha256:1f298b0c9fecdf504389a0329236f948cc04a566a2bb32337207cbaaa2f8177c AS builder
WORKDIR /build
# Copy every Go source file, not just main.go: the sandbox hardening lives in
# harden.go (portable) plus harden_unix.go / harden_other.go (per-platform).
COPY go.mod ./
COPY main.go harden.go harden_unix.go harden_other.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/service .

# The scripting toolchains, one image for eleven interpreters. Ruby, Perl, PHP,
# Lua, Tcl, Bash, sh, AWK, R, Raku and Julia are all single binaries with no
# distinct compiler, so giving each its own service would multiply the Debian
# base eleven times and buy nothing. This is the toolchain set
# codhoot-runner-scripting installs, from the same Debian bookworm packages.
FROM python:3.12-slim-bookworm@sha256:9901e0a8d75037d8242ed43155cbcb2d1f61be1356383d8054afb59fd50e39c4
LABEL org.opencontainers.image.title="codhoot-scripting-service"
LABEL org.opencontainers.image.description="Hardened scripting execution sandbox (ruby, lua, php, tcl, perl, bash, sh, awk, r, raku, julia)"
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        lua5.4 \
        ruby \
        perl \
        php-cli \
        tcl \
        bash \
        rakudo \
        ca-certificates; \
    # Stable interpreter names, so a registry entry never has to know where
    # Debian happened to put a versioned binary. lua5.4 in particular is not
    # called `lua` unless the alternative is installed.
    ln -sf /usr/bin/lua5.4 /usr/local/bin/lua; \
    ln -sf /usr/bin/tclsh /usr/local/bin/tclsh; \
    rm -rf /var/lib/apt/lists/*

# Julia ships as an upstream release archive with its own bundled toolchain, the
# same shape codhoot-runner-scripting installs. The archive is sha256-pinned
# against the hash julialang publishes, so a mirror serving different bytes
# fails the build instead of installing them.
ARG JULIA_VERSION=1.10.5
ARG JULIA_SHA256=33497b93cf9dd65e8431024fd1db19cbfbe30bd796775a59d53e2df9a8de6dc0

RUN set -eux; \
    apt-get update; \
    # --reinstall, not a plain install: the base image has no curl binary but
    # keeps dpkg's record, so a plain install reports "already the newest
    # version" and leaves curl missing.
    apt-get install -y --no-install-recommends --reinstall curl ca-certificates; \
    apt-get install -y --no-install-recommends r-base-core; \
    curl -fsSL -A "codhoot-image-build" -o /tmp/julia.tar.gz \
      "https://mirrors.ustc.edu.cn/julia-releases/bin/linux/x64/1.10/julia-${JULIA_VERSION}-linux-x86_64.tar.gz"; \
    echo "${JULIA_SHA256}  /tmp/julia.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/toolchains/julia; \
    tar -xzf /tmp/julia.tar.gz -C /opt/toolchains/julia --strip-components=1; \
    rm -f /tmp/julia.tar.gz; \
    ln -sf /opt/toolchains/julia/bin/julia /usr/local/bin/julia; \
    ln -sf /usr/bin/Rscript /usr/local/bin/Rscript; \
    # Fetch tooling has done its job; the shipped image carries none, matching
    # every other CodHoot sandbox.
    apt-get purge -y --auto-remove curl; \
    rm -f /usr/bin/curl /usr/bin/wget /usr/local/bin/curl /usr/local/bin/wget; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Smoke test every interpreter this service advertises at build time: a runtime
# the image cannot execute is worse than a failed build, and a missing binary
# here would otherwise only surface as a failed first student submission.
RUN set -eux; \
    command -v awk bash sh lua perl php ruby tclsh raku Rscript julia; \
    lua -e 'print("lua ok")'; \
    ruby -e 'puts "ruby ok"'; \
    perl -e 'print "perl ok\n"'; \
    php -r 'echo "php ok\n";'; \
    Rscript -e 'cat("r ok\n")'; \
    bash -c 'echo "bash ok"'; \
    awk 'BEGIN { print "awk ok" }'

WORKDIR /app
COPY --from=builder /out/service /app/service
RUN chmod 0755 /app/service && rm -f go.mod main.go harden.go harden_unix.go harden_other.go

# --- sandbox identity pool ---------------------------------------------------
# Each in-flight job is dropped to a DISTINCT uid by the service. That is what
# makes a job's 0700 working directory genuinely private: with one shared uid every
# job could read every other job's source and rewrite it before it ran.
# Runtimes that resolve getpwuid need real passwd entries, written directly here
# rather than with 32 useradd calls.
# shellcheck disable=SC2016
RUN set -eu; \
    i=0; \
    while [ "$i" -lt 32 ]; do \
      u=$((2000 + i)); \
      printf 'codhoot-s%d:x:%d:%d:codhoot sandbox:/nonexistent:/sbin/nologin\n' "$i" "$u" "$u" >> /tmp/pool; \
      i=$((i + 1)); \
    done; \
    cat /tmp/pool >> /etc/passwd; \
    rm -f /tmp/pool; \
    mkdir -p /tmp/codhoot-cache; \
    chmod 0755 /tmp/codhoot-cache

# The service itself runs as root on purpose: it must chown each job directory to
# that job's uid and setuid the interpreter child. The security boundary is
# the child, not the service.
#
# There is deliberately no HEALTHCHECK here: it would require curl or wget in the
# image, and Render already health-checks /health over HTTP.
ENV PORT=8081
EXPOSE 8081
CMD ["/app/service"]