#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PACKAGE_DIR}/.." && pwd)"
CRATE_DIR="${REPO_ROOT}/codex-rs/mobile-core"
BUILD_DIR="${PACKAGE_DIR}/.build/mobile-core"
ARTIFACT_DIR="${PACKAGE_DIR}/Artifacts"
XCFRAMEWORK="${ARTIFACT_DIR}/CodexMobileCore.xcframework"
IOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-26.0}"
MACOS_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"

if command -v rustup >/dev/null 2>&1; then
  CARGO_BIN="$(rustup which cargo 2>/dev/null || true)"
  RUSTC_BIN="$(rustup which rustc 2>/dev/null || true)"
else
  CARGO_BIN=""
  RUSTC_BIN=""
fi

if [[ -z "${CARGO_BIN}" ]]; then
  CARGO_BIN="$(command -v cargo || true)"
fi

if [[ -z "${RUSTC_BIN}" ]]; then
  RUSTC_BIN="$(command -v rustc || true)"
fi

if [[ -z "${CARGO_BIN}" ]]; then
  echo "cargo is required to build CodexMobileCore.xcframework" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required to create CodexMobileCore.xcframework" >&2
  exit 1
fi

mkdir -p "${BUILD_DIR}/include" "${ARTIFACT_DIR}"
rm -rf "${XCFRAMEWORK}"

cat >"${BUILD_DIR}/include/CodexMobileCore.h" <<'HEADER'
#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct CodexMobileBuffer {
    uint8_t *ptr;
    size_t len;
} CodexMobileBuffer;

void codex_mobile_buffer_free(CodexMobileBuffer buffer);
CodexMobileBuffer codex_mobile_core_version_json(void);
CodexMobileBuffer codex_mobile_provider_defaults_json(void);
CodexMobileBuffer codex_mobile_builtin_tools_json(void);
CodexMobileBuffer codex_mobile_build_responses_request_json(const char *input);
CodexMobileBuffer codex_mobile_parse_sse_event_json(const char *input);
CodexMobileBuffer codex_mobile_tool_output_json(const char *input);
CodexMobileBuffer codex_mobile_emulate_shell_json(const char *input);
CodexMobileBuffer codex_mobile_apply_patch_json(const char *input);
CodexMobileBuffer codex_mobile_device_code_request_json(const char *input);
CodexMobileBuffer codex_mobile_refresh_token_request_json(const char *input);
CodexMobileBuffer codex_mobile_authorization_url_json(const char *input);
CodexMobileBuffer codex_mobile_authorization_code_token_request_json(const char *input);
CodexMobileBuffer codex_mobile_parse_chatgpt_token_claims_json(const char *input);
CodexMobileBuffer codex_mobile_device_key_signing_payload_json(const char *input);
HEADER

cat >"${BUILD_DIR}/include/module.modulemap" <<'MODULEMAP'
module CodexMobileCore {
    header "CodexMobileCore.h"
    export *
}
MODULEMAP

build_target() {
  local target="$1"
  case "${target}" in
    aarch64-apple-ios | aarch64-apple-ios-sim)
      IPHONEOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" RUSTC="${RUSTC_BIN}" "${CARGO_BIN}" build \
        --manifest-path "${CRATE_DIR}/Cargo.toml" \
        --target "${target}" \
        --release
      ;;
    aarch64-apple-darwin)
      MACOSX_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET}" RUSTC="${RUSTC_BIN}" "${CARGO_BIN}" build \
        --manifest-path "${CRATE_DIR}/Cargo.toml" \
        --target "${target}" \
        --release
      ;;
    *)
      RUSTC="${RUSTC_BIN}" "${CARGO_BIN}" build \
        --manifest-path "${CRATE_DIR}/Cargo.toml" \
        --target "${target}" \
        --release
      ;;
  esac
}

build_target aarch64-apple-ios
build_target aarch64-apple-ios-sim
build_target aarch64-apple-darwin

xcodebuild -create-xcframework \
  -library "${REPO_ROOT}/codex-rs/target/aarch64-apple-ios/release/libcodex_mobile_core.a" \
  -headers "${BUILD_DIR}/include" \
  -library "${REPO_ROOT}/codex-rs/target/aarch64-apple-ios-sim/release/libcodex_mobile_core.a" \
  -headers "${BUILD_DIR}/include" \
  -library "${REPO_ROOT}/codex-rs/target/aarch64-apple-darwin/release/libcodex_mobile_core.a" \
  -headers "${BUILD_DIR}/include" \
  -output "${XCFRAMEWORK}"

echo "Wrote ${XCFRAMEWORK}"
