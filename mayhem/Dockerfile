# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base). The base provides debian + clang/llvm + libFuzzer + the
# identities + the build-contract ENV. starlark-rust is a RUST workspace, and the base ships NO
# Rust toolchain, so this image installs rustup (nightly) + cargo-fuzz as root into a SHARED
# location (/opt/rust) usable by the non-root `mayhem` user, then runs build.sh + test.sh.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t starlark-rust-commit:test .

FROM ghcr.io/mayhemheroes/base:2026-06

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default,
# but cargo-fuzz drives Rust instrumentation via RUSTFLAGS (-Zsanitizer=address), NOT $SANITIZER_FLAGS.
# Declared here for parity; build.sh wires ASan into RUSTFLAGS the cargo-fuzz way.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Pin the nightly toolchain (cargo-fuzz needs nightly for `-Z` flags / -Zsanitizer=address).
# Mirrors OSS-Fuzz's base-builder-rust which pins a dated nightly.
ARG RUST_TOOLCHAIN=nightly-2025-09-05
ARG CARGO_FUZZ_VERSION=0.12.0

# Shared Rust install: CARGO_HOME/RUSTUP_HOME under /opt/rust, world-readable, so the non-root
# `mayhem` user can invoke cargo/rustc/cargo-fuzz without owning the toolchain.
ENV RUSTUP_HOME=/opt/rust/rustup \
    CARGO_HOME=/opt/rust/cargo \
    PATH=/opt/rust/cargo/bin:$PATH

USER root
RUN set -eux; \
    mkdir -p "$RUSTUP_HOME" "$CARGO_HOME"; \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_TOOLCHAIN"; \
    rustup component add rust-src --toolchain "$RUST_TOOLCHAIN"; \
    cargo install cargo-fuzz --version "$CARGO_FUZZ_VERSION" --locked; \
    # The non-root `mayhem` user runs `cargo fuzz build`, which WRITES into CARGO_HOME (registry
    # cache, git checkouts). Toolchain dirs stay read-only; the cargo home must be group/other
    # writable so the build can populate the registry. (Build image, not a hardened runtime.)
    chmod -R a+rX /opt/rust; \
    chmod -R a+rwX "$CARGO_HOME/registry" "$CARGO_HOME/git" 2>/dev/null || true; \
    mkdir -p "$CARGO_HOME/registry" "$CARGO_HOME/git" && chmod -R a+rwX "$CARGO_HOME/registry" "$CARGO_HOME/git"; \
    rustc --version; cargo --version; cargo fuzz --version; \
    # DWARF3 anchor: cargo-fuzz links librustc-nightly_rt.asan.a (DWARF5) via --whole-archive so
    # it lands at offset 0 in .debug_info, defeating -Zdwarf-version=3 alone. Compile a tiny empty
    # anchor.c with -gdwarf-3 and inject it via a cc-wrapper so its DWARF3 CU sits at offset 0
    # (the first CU determines the version that verify-repo's readelf -m1 check reads). (§6.2 item 10)
    mkdir -p /opt/mayhem-dwarf3-anchor; \
    printf 'void mayhem_dwarf3_anchor(void){}\n' > /tmp/anchor.c; \
    clang -g -gdwarf-3 -c /tmp/anchor.c -o /opt/mayhem-dwarf3-anchor/anchor.o; \
    printf '#!/bin/sh\nexec cc /opt/mayhem-dwarf3-anchor/anchor.o "$@"\n' \
      > /opt/mayhem-dwarf3-anchor/cc-wrapper.sh; \
    chmod +x /opt/mayhem-dwarf3-anchor/cc-wrapper.sh; \
    rm /tmp/anchor.c
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history)
# is copied to /mayhem as `mayhem`; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run starlark-rust's real test suite (parser + evaluator known-answer tests) at build time; a
# failing suite fails the image build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
