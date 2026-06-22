#!/usr/bin/env bash
#
# starlark-rust/mayhem/build.sh — build facebook/starlark-rust's cargo-fuzz target as a sanitized
# libFuzzer binary, replicating OSS-Fuzz's Rust path (oss-fuzz/projects/starlark-rust/build.sh,
# which `cd starlark; cargo +nightly fuzz build -O` and ships every fuzz/fuzz_targets/*.rs binary
# from fuzz/target/x86_64-unknown-linux-gnu/release).
#
# starlark-rust is a pure-Rust Starlark language interpreter (a Bazel/Buck config dialect of
# Python). The fuzz target parses + evaluates an arbitrary Starlark program (`&str` input):
#   AstModule::parse -> Evaluator::eval_module, panicking only on an "internal error" anyhow.
#
# Layout note: the fuzz crate (starlark/fuzz) declares `[workspace] members = ["."]`, so it is its
# OWN nested cargo workspace (NOT a member of the top-level workspace). cargo-fuzz therefore emits
# the binary under starlark/fuzz/target/<triple>/release — exactly the path OSS-Fuzz's build.sh
# copies from. We resolve that target dir from `cargo metadata` (robust to layout changes) rather
# than assuming it, falling back to the conventional fuzz/target.
#
# cargo-fuzz drives the build:
#   - it provides its own libFuzzer runtime (the produced binary IS a libFuzzer target — Mayhem
#     runs it directly via `libfuzzer: true`);
#   - ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS / CFLAGS — those don't apply to rustc), which is exactly what OSS-Fuzz's
#     `compile` sets for FUZZING_LANGUAGE=rust. nightly is required for `-Zsanitizer`.
#
# Target (starlark/fuzz/fuzz_targets/*.rs):
#   starlark  — the OSS-Fuzz target; parses + evaluates an arbitrary Starlark program.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even though
# the Rust build doesn't invoke clang directly; cargo's cc-built deps might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

TRIPLE="x86_64-unknown-linux-gnu"

# The cargo-fuzz crate lives in starlark/fuzz (cargo-fuzz convention; the OSS-Fuzz build.sh does
# `cd starlark` then builds). It is a self-contained nested workspace.
FUZZ_DIR="$SRC/starlark/fuzz"
# cargo-fuzz binary names = the [[bin]] names in starlark/fuzz/Cargo.toml (currently just
# `starlark`). NOTE: the repo root copied to /mayhem already contains a `starlark/` SOURCE
# directory, so copying the binary to /mayhem/<binname> with binname=starlark would collide with
# that directory (the cp lands inside it). We therefore map each cargo-fuzz binary to an output
# name with a `-fuzz` suffix under /mayhem. Keep this map in sync with the Mayhemfile `cmd:` paths.
FUZZ_BINS=(starlark)            # cargo-fuzz [[bin]] names (built under the release dir)
declare -A OUT_NAME=( [starlark]=starlark-fuzz )   # binname -> /mayhem/<output> (avoids dir clash)

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. cargo-fuzz sets the ASan
# flag itself by default, but we set it explicitly so the behavior is pinned and visible. `--cfg
# fuzzing` matches what libfuzzer-sys expects; force-frame-pointers aids ASan stack traces.
# Debug-info contract (SPEC §6.2 item 10): thread $RUST_DEBUG_FLAGS so the fuzz binary carries a
# .debug_info section with DWARF < 4 (Mayhem triage cannot read DWARF >= 4). The default forces
# DWARF-3 via rustc (-Zdwarf-version=3, nightly); the prebuilt std rlibs (DWARF-4) and the ASan
# runtime archive (DWARF-5) are debug-stripped in the Dockerfile so no CU >= 4 survives the link.
# The flags are a single env knob so the rlenv PATCH tier can override them; we do not fight an
# externally-set value.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -Zdwarf-version=3}"

export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address -Cforce-frame-pointers ${RUST_DEBUG_FLAGS}"
# libfuzzer-sys compiles a bundled libFuzzer via the cc crate (clang -> DWARF-5 by default); force
# DWARF-3 on those C/C++ objects too, so NO compilation unit in the linked binary is >= 4.
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"

# Force a clean relink so no stale DWARF-5 object lingers from a prior cache (memory: old-rust-dwarf).
rm -rf "$FUZZ_DIR/target"

# cargo-fuzz must run from inside the fuzz crate dir (nested workspace). Use the image's DEFAULT
# toolchain (Dockerfile pins it to the required nightly); a `+toolchain` override would make rustup
# try to install a different channel into the read-only shared /opt/toolchains/rust. `-O` (release
# w/ opt) + `--debug-assertions` mirrors OSS-Fuzz's build.sh (catches overflow/debug asserts during
# fuzzing). cargo-fuzz 0.12 doesn't accept --jobs; parallelism is via CARGO_BUILD_JOBS.
echo "--- cargo fuzz build (all targets) ---"
( cd "$FUZZ_DIR" && cargo fuzz build -O --debug-assertions )

# Resolve the fuzz crate's target dir from cargo metadata (it's a nested workspace, so this is
# starlark/fuzz/target), falling back to the conventional path.
TARGET_DIR="$(cd "$FUZZ_DIR" && cargo metadata --no-deps --format-version 1 2>/dev/null \
  | sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p')"
[ -n "$TARGET_DIR" ] || TARGET_DIR="$FUZZ_DIR/target"
RELEASE_DIR="$TARGET_DIR/$TRIPLE/release"
echo "RELEASE_DIR=$RELEASE_DIR"

OUT_PATHS=()
for t in "${FUZZ_BINS[@]}"; do
  bin="$RELEASE_DIR/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    echo "--- contents of $RELEASE_DIR ---" >&2
    ls -la "$RELEASE_DIR" 2>&1 >&2 || true
    exit 1
  fi
  out="/mayhem/${OUT_NAME[$t]:-$t}"
  cp "$bin" "$out"
  OUT_PATHS+=("$out")
  echo "built $out"
done

echo "build.sh complete:"
ls -la "${OUT_PATHS[@]}" 2>&1 || true
