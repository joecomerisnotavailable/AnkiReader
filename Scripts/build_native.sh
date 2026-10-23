#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export RUSTUP_HOME="$PWD/.tools/rustup"
export CARGO_HOME="$PWD/.tools/cargo"
export PATH="$CARGO_HOME/bin:$PATH"
python3 Scripts/patch_sudachi.py
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin; do
  cargo build --manifest-path Native/Cargo.toml --release --target "$target"
done
