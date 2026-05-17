#!/bin/bash
set -euo pipefail

V8_VERSION=${1:?missing V8 version}
BUILD_ARGS=${2:-}

echo "=========================================="
echo "Building v8dasm for Android ARM64"
echo "V8 Version: $V8_VERSION"
echo "Build Args: $BUILD_ARGS"
echo "=========================================="

if [ -z "${GITHUB_WORKSPACE:-}" ]; then
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    WORKSPACE_DIR="$( cd "$SCRIPT_DIR/../.." && pwd )"
else
    WORKSPACE_DIR="$GITHUB_WORKSPACE"
fi

echo "Workspace: $WORKSPACE_DIR"

git config --global user.name "V8 Disassembler Builder"
git config --global user.email "v8dasm.builder@localhost"
git config --global core.autocrlf false
git config --global core.filemode false

cd "$WORKSPACE_DIR"

if [ ! -d depot_tools ]; then
    echo "=====[ Getting Depot Tools ]====="
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
fi
export PATH="$WORKSPACE_DIR/depot_tools:$PATH"
gclient

mkdir -p v8
cd v8

if [ ! -d v8 ]; then
    echo "=====[ Fetching V8 ]====="
    fetch v8
fi

python3 - <<'PY'
from pathlib import Path

path = Path(".gclient")
text = path.read_text(encoding="utf-8") if path.exists() else ""
if "target_os" in text:
    import re
    text = re.sub(r"target_os\s*=\s*\[[^\]]*\]", "target_os = ['android']", text)
else:
    if text and not text.endswith("\n"):
        text += "\n"
    text += "target_os = ['android']\n"
path.write_text(text, encoding="utf-8")
PY

cd v8
V8_DIR=$(pwd)

echo "=====[ Checking out V8 $V8_VERSION ]====="
git fetch --all --tags
git checkout "$V8_VERSION"
gclient sync

echo "=====[ Applying v8.patch ]====="
PATCH_FILE="$WORKSPACE_DIR/Disassembler/v8.patch"
PATCH_LOG="$WORKSPACE_DIR/scripts/v8dasm-builders/patch-utils/patch-state.log"

bash "$WORKSPACE_DIR/scripts/v8dasm-builders/patch-utils/apply-patch.sh" \
    "$PATCH_FILE" \
    "$V8_DIR" \
    "$PATCH_LOG" \
    "true"

echo "=====[ Adding Android v8dasm GN target ]====="
cp "$WORKSPACE_DIR/Disassembler/v8dasm.cpp" tools/v8dasm.cpp

if ! grep -q 'v8_executable("v8dasm")' BUILD.gn; then
    cat >> BUILD.gn <<'GN'

v8_executable("v8dasm") {
  sources = [ "tools/v8dasm.cpp" ]

  configs = [
    ":internal_config_base",
  ]

  deps = [
    ":v8",
    ":v8_libbase",
    ":v8_libplatform",
  ]
}
GN
fi

echo "=====[ Configuring V8 Build for Android ARM64 ]====="
GN_ARGS='target_os="android" target_cpu="arm64" v8_target_cpu="arm64" is_component_build=false is_debug=false v8_monolithic=true v8_static_library=true v8_enable_disassembler=true v8_enable_object_print=true v8_use_external_startup_data=false v8_enable_pointer_compression=false v8_enable_sandbox=false v8_enable_31bit_smis_on_64bit_arch=false v8_enable_short_builtin_calls=false dcheck_always_on=false symbol_level=0 v8_android_log_stdout=true'

if [ -n "$BUILD_ARGS" ]; then
    GN_ARGS="$GN_ARGS $BUILD_ARGS"
fi

echo "GN Args: $GN_ARGS"
gn gen out.gn/android_arm64.release --args="$GN_ARGS"

echo "=====[ Building Android ARM64 v8dasm ]====="
ninja -C out.gn/android_arm64.release v8dasm

OUTPUT_NAME="v8dasm-$V8_VERSION-android-arm64"
cp out.gn/android_arm64.release/v8dasm "$OUTPUT_NAME"
chmod +x "$OUTPUT_NAME"

if [ -f "$OUTPUT_NAME" ]; then
    echo "=====[ Build Successful ]====="
    ls -lh "$OUTPUT_NAME"
    file "$OUTPUT_NAME"
    echo "Built: $V8_DIR/$OUTPUT_NAME"
else
    echo "ERROR: $OUTPUT_NAME binary not found!"
    exit 1
fi
