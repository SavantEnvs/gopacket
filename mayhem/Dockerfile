# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — GO target (go modules / go-fuzz-build). Builds ON TOP
# of the org C/C++ base (ghcr.io/savantenvs/base) — clang is needed to link the
# go-fuzz libFuzzer archive — adding a pinned Go toolchain + go-fuzz under
# /opt/toolchains/go, then runs the per-repo mayhem/build.sh.
#
# WHY a Go-specific template (SPEC §6.2 items 8/9, §6.5):
#   Go's GOPATH/GOMODCACHE default to $HOME/go. The commit build and the PATCH RL
#   re-run use DIFFERENT $HOMEs, so a cache left at the default would vanish under
#   the re-run identity. We pin GOROOT/GOPATH/GOMODCACHE at FIXED, $HOME-independent
#   paths under /opt/toolchains so (a) the toolchain locks uniformly and (b) the
#   module cache the FIRST (online) build fills is found again — by the SAME
#   absolute GOMODCACHE — when build.sh re-runs OFFLINE at the PATCH tier.
#
# gopacket ships its OWN legacy `func FuzzLayer(data []byte) int` fuzz target
# (layers/fuzz_layer.go) — the dvyukov/go-fuzz path, not go-118-fuzz-build.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t mytag .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS

# ── Go toolchain @ a FIXED, lockable, $HOME-independent prefix ─────────────────
# Pin the Go version AND its tarball sha256 (reproducible fetch). Pin go-fuzz by a
# module pseudo-version (NOT @latest) so the cache is deterministic.
# NOTE: the fleet-proven 1.23.4 pin is NOT usable here — this go-fuzz pseudo-version
# pulls in golang.org/x/tools v0.49.0, which requires go >= 1.25.0 to resolve (confirmed
# by a failed build attempt); 1.25.1 (matching the legacy mayhemheroes integration) is
# the minimum that satisfies it.
ARG GO_VERSION=1.25.1
ARG GO_SHA256=7716a0d940a0f6ae8e1f3b3f4f36299dc53e31b16840dbd171254312c41ca12e
ARG GO_FUZZ_VERSION=v0.0.0-20240924070022-e577bee5275c
# go-fuzz's go.mod leaves x/tools unpinned, so a bare `go install` takes the newest, which needs a newer Go.
ARG XTOOLS_VERSION=v0.38.0

ENV GOROOT=/opt/toolchains/go \
    GOPATH=/opt/toolchains/go-path \
    GOMODCACHE=/opt/toolchains/go-path/pkg/mod \
    GOCACHE=/opt/toolchains/go-path/build-cache \
    GOTOOLCHAIN=local \
    GOFLAGS=-mod=mod \
    PATH=/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:${PATH}

USER root
# libpcap headers/lib: needed by the pcap package (cgo) so its test suite compiles+runs.
RUN apt-get update -qq && apt-get install -y --no-install-recommends libpcap-dev \
 && rm -rf /var/lib/apt/lists/*
RUN install -d /opt/toolchains/go-path \
 && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz \
 && echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c - \
 && tar -C /opt/toolchains -xzf /tmp/go.tgz && rm -f /tmp/go.tgz \
 # go-fuzz + go-fuzz-build (the libFuzzer build path). Installing them also seeds the
 # go-fuzz module (incl. go-fuzz-dep) into GOMODCACHE, which build.sh needs offline.
 && mkdir /tmp/gofuzz-src && cd /tmp/gofuzz-src && go mod init gofuzz-tools \
 && go get "golang.org/x/tools@${XTOOLS_VERSION}" "github.com/dvyukov/go-fuzz@${GO_FUZZ_VERSION}" \
 && go install github.com/dvyukov/go-fuzz/go-fuzz github.com/dvyukov/go-fuzz/go-fuzz-build \
 && cd / && rm -rf /tmp/gofuzz-src \
 # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): it must
 # read the toolchain and read/refresh the module cache, so hand the GOPATH to 2000.
 && chown -R 2000:2000 /opt/toolchains/go-path

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $GOMODCACHE (online, this first build) and builds the libFuzzer target(s).
RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      rlenv.fix="68f08e6fa7f250bc7b1ace020577c01bc079a64c" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
