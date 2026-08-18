#!/usr/bin/env bash
#
# gopacket/mayhem/build.sh — build google/gopacket's own go-fuzz harness
# (layers/fuzz_layer.go: `func FuzzLayer(data []byte) int`) as a sanitized
# libFuzzer binary via the OSS-Fuzz Go path (go-fuzz-build -libfuzzer + clang link),
# plus the mayhem/kat known-answer probe used by mayhem/test.sh.
#
# The harness is UPSTREAM's OWN fuzz target (shipped in the layers package); it
# decodes arbitrary bytes as a packet starting from a fuzz-chosen LayerType and
# stringifies every decoded layer — the fuzzed surface is gopacket's whole
# layer-decoding stack. It takes bytes only from the fuzzer (no file I/O), so it
# needs no adaptation for Mayhem's read-only /mayhem cwd.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
# The first (online) build fills $GOMODCACHE; GOPROXY lists the in-image file
# proxy FIRST so the offline re-run resolves entirely from the cache.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASan-only for the libFuzzer link.
: "${SANITIZER_FLAGS=-fsanitize=address}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS MAYHEM_JOBS

# Debug-info flags (DWARF <= 3): the C shim compiled by clang is forced to
# DWARF3 so the binary's first CU passes the DWARF < 4 gate (Go's gc compiler has
# no DWARF-version knob).
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Resolve modules offline-first from the in-image cache; network only as fallback.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

: "${SRC:=/mayhem}"
cd "$SRC"
go version

# Fill the module cache with everything the build AND the test suite need, so the
# offline PATCH re-run (and mayhem/test.sh) resolve entirely from the cache.
go mod download all

# go-fuzz-build needs go-fuzz-dep on the module graph (resolves from the cache offline).
go get github.com/dvyukov/go-fuzz/go-fuzz-dep

mkdir -p "$SRC/mayhem-build"

# ── fuzz_layers: upstream's layers.FuzzLayer via go-fuzz-build -libfuzzer ──────
# Preserve the historical Mayhem target name `fuzz_layers` for run-history continuity.
TARGET="fuzz_layers"
echo "=== building $TARGET (go-fuzz-build -libfuzzer -func FuzzLayer ./layers) ==="
(
  cd "$SRC/layers"
  go-fuzz-build -libfuzzer -func FuzzLayer -o "$SRC/mayhem-build/$TARGET.a"
)
# Link the go-fuzz archive into a libFuzzer binary with clang (ASan, DWARF3 shim).
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/$TARGET.a" -o "/mayhem/$TARGET"
echo "built /mayhem/$TARGET"

# ── mayhem/kat: dynamically-linked known-answer probe (anti-reward-hacking) ────
# `go test` links a STATIC binary that the verify-repo LD_PRELOAD sabotage shim
# cannot neuter. This probe is forced to cgo/external-linking (mayhem/kat/cgo_dynamic.go)
# so it IS dynamically linked and reachable by the shim, then decodes a fixed,
# upstream-authored packet fixture and prints exact field values that mayhem/test.sh
# asserts — normal flags only (no sanitizer/fuzz instrumentation; it is a functional
# oracle, not a triage artifact).
echo "=== building /mayhem/kat (KAT probe, cgo => dynamically linked) ==="
CGO_ENABLED=1 CGO_CFLAGS="$GO_DEBUG_FLAGS" go build -o /mayhem/kat ./mayhem/kat
if ! file /mayhem/kat | grep -q 'dynamically linked'; then
  echo "FATAL: /mayhem/kat is not dynamically linked — the sabotage check could not" >&2
  echo "       neuter it, which would make mayhem/test.sh a reward-hackable oracle." >&2
  file /mayhem/kat >&2
  exit 1
fi
echo "built /mayhem/kat (dynamically linked)"

# Go's `go test` compiles on demand, so there is no separate test-suite build step;
# mayhem/test.sh runs it with the project's normal flags.

echo "build.sh complete:"
ls -la /mayhem/fuzz_layers /mayhem/kat
