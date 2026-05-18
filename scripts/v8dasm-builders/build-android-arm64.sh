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

echo "=====[ Applying Android d8 loadjsc compatibility fixes ]====="
python3 - <<'PY'
from pathlib import Path

d8cc = Path("src/d8/d8.cc")
text = d8cc.read_text(encoding="utf-8")
if "#include <unordered_set>" not in text:
    text = text.replace("#include <unordered_map>\n", "#include <unordered_map>\n#include <unordered_set>\n", 1)
d8cc.write_text(text, encoding="utf-8")

logging_h = Path("src/base/logging.h")
text = logging_h.read_text(encoding="utf-8")
needle = "#define UNREACHABLE() FATAL(::v8::base::kUnreachableCodeMessage)"
replacement = (
    "#define UNREACHABLE() "
    'FATAL("unreachable code at %s:%d", __FILE__, __LINE__)'
)
if needle not in text:
    raise SystemExit("UNREACHABLE macro patch point not found")
text = text.replace(needle, replacement, 1)
logging_h.write_text(text, encoding="utf-8")

deserializer = Path("src/snapshot/deserializer.cc")
text = deserializer.read_text(encoding="utf-8")
start = text.index("class SlotAccessorForHandle")
end = text.index("\n};", start) + len("\n};")
prefix, block, suffix = text[:start], text[start:end], text[end:]
block = block.replace(
    "  int Write(Tagged<MaybeObject> value, int slot_offset = 0) { UNREACHABLE(); }\n",
    "  int Write(Tagged<MaybeObject> value, int slot_offset = 0) {\n"
    "    DCHECK_EQ(slot_offset, 0);\n"
    "    *handle_ = handle(HeapObject::cast(value.GetHeapObjectAssumeStrong()), isolate_);\n"
    "    return 1;\n"
    "  }\n",
    1,
)
block = block.replace(
    "  int WriteIndirectPointerTo(Tagged<HeapObject> value) { UNREACHABLE(); }\n"
    "  int WriteProtectedPointerTo(Tagged<TrustedObject> value) { UNREACHABLE(); }\n",
    "  int WriteIndirectPointerTo(Tagged<HeapObject> value) {\n"
    "    *handle_ = handle(value, isolate_);\n"
    "    return 1;\n"
    "  }\n"
    "  int WriteProtectedPointerTo(Tagged<TrustedObject> value) {\n"
    "    *handle_ = handle(HeapObject::cast(value), isolate_);\n"
    "    return 1;\n"
    "  }\n",
    1,
)
text = prefix + block + suffix
tags = {
    "ExternalPointerSlot external_pointer_slot(ExternalPointerTag tag) const {\n    UNREACHABLE();\n  }":
        "ExternalPointerSlot external_pointer_slot(ExternalPointerTag tag) const {\n    PrintF(\"[deserialize-unreachable] root external_pointer_slot\\\\n\"); fflush(stdout);\n    UNREACHABLE();\n  }",
    "Handle<HeapObject> object() const { UNREACHABLE(); }\n  int offset() const { UNREACHABLE(); }":
        "Handle<HeapObject> object() const { PrintF(\"[deserialize-unreachable] object accessor\\\\n\"); fflush(stdout); UNREACHABLE(); }\n  int offset() const { PrintF(\"[deserialize-unreachable] offset accessor\\\\n\"); fflush(stdout); UNREACHABLE(); }",
    "int WriteIndirectPointerTo(Tagged<HeapObject> value) { UNREACHABLE(); }\n  int WriteProtectedPointerTo(Tagged<TrustedObject> value) { UNREACHABLE(); }":
        "int WriteIndirectPointerTo(Tagged<HeapObject> value) { PrintF(\"[deserialize-unreachable] root indirect pointer\\\\n\"); fflush(stdout); UNREACHABLE(); }\n  int WriteProtectedPointerTo(Tagged<TrustedObject> value) { PrintF(\"[deserialize-unreachable] root protected pointer\\\\n\"); fflush(stdout); UNREACHABLE(); }",
    "MaybeObjectSlot slot() const { UNREACHABLE(); }\n  ExternalPointerSlot external_pointer_slot(ExternalPointerTag tag) const {\n    UNREACHABLE();\n  }":
        "MaybeObjectSlot slot() const { PrintF(\"[deserialize-unreachable] handle slot\\\\n\"); fflush(stdout); UNREACHABLE(); }\n  ExternalPointerSlot external_pointer_slot(ExternalPointerTag tag) const {\n    PrintF(\"[deserialize-unreachable] handle external_pointer_slot\\\\n\"); fflush(stdout);\n    UNREACHABLE();\n  }",
    "void Deserializer<LocalIsolate>::PostProcessNewJSReceiver(\n    Tagged<Map> map, Handle<JSReceiver> obj, InstanceType instance_type,\n    SnapshotSpace space) {\n  UNREACHABLE();\n}":
        "void Deserializer<LocalIsolate>::PostProcessNewJSReceiver(\n    Tagged<Map> map, Handle<JSReceiver> obj, InstanceType instance_type,\n    SnapshotSpace space) {\n  PrintF(\"[deserialize-unreachable] LocalIsolate::PostProcessNewJSReceiver\\\\n\"); fflush(stdout);\n  UNREACHABLE();\n}",
}
for needle, replacement in tags.items():
    text = text.replace(needle, replacement, 1)
deserializer.write_text(text, encoding="utf-8")
PY

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

echo "=====[ Building Android ARM64 v8dasm and patched d8 ]====="
ninja -C out.gn/android_arm64.release v8dasm d8

OUTPUT_NAME="v8dasm-$V8_VERSION-android-arm64"
cp out.gn/android_arm64.release/v8dasm "$OUTPUT_NAME"
chmod +x "$OUTPUT_NAME"

D8_OUTPUT_NAME="d8-$V8_VERSION-android-arm64"
cp out.gn/android_arm64.release/d8 "$D8_OUTPUT_NAME"
chmod +x "$D8_OUTPUT_NAME"

if [ -f "$OUTPUT_NAME" ] && [ -f "$D8_OUTPUT_NAME" ]; then
    echo "=====[ Build Successful ]====="
    ls -lh "$OUTPUT_NAME"
    ls -lh "$D8_OUTPUT_NAME"
    file "$OUTPUT_NAME"
    file "$D8_OUTPUT_NAME"
    echo "Built: $V8_DIR/$OUTPUT_NAME"
    echo "Built: $V8_DIR/$D8_OUTPUT_NAME"
else
    echo "ERROR: expected output binary not found!"
    exit 1
fi
