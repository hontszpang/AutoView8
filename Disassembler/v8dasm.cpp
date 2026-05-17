#include <fstream>
#include <iostream>
#include <limits>
#include <string>
#include <cstdlib>
#include <vector>

#include "include/v8.h"
#include "include/libplatform/libplatform.h"
#include "src/codegen/script-details.h"
#include "src/codegen/cpu-features.h"
#include "src/flags/flags.h"
#include "src/handles/handles.h"
#include "src/objects/shared-function-info.h"
#include "src/snapshot/code-serializer.h"

using namespace v8;

static Isolate* isolate = nullptr;

static uint32_t readU32LE(const uint8_t* data, int length, int offset) {
  if (offset < 0 || offset + 4 > length) return 0;
  return static_cast<uint32_t>(data[offset]) |
         (static_cast<uint32_t>(data[offset + 1]) << 8) |
         (static_cast<uint32_t>(data[offset + 2]) << 16) |
         (static_cast<uint32_t>(data[offset + 3]) << 24);
}

static void applyCpuFeaturesOverrideFromEnv() {
  const char* value = std::getenv("V8DASM_CPU_FEATURES_HEX");
  if (value == nullptr || value[0] == '\0') return;

  const unsigned forced = static_cast<unsigned>(std::strtoul(value, nullptr, 0));
  v8::internal::CpuFeatures::SupportedFeatures();
  for (int i = 0; i < v8::internal::NUMBER_OF_CPU_FEATURES; i++) {
    const auto feature = static_cast<v8::internal::CpuFeature>(i);
    if ((forced & (1u << i)) != 0) {
      v8::internal::CpuFeatures::SetSupported(feature);
    } else {
      v8::internal::CpuFeatures::SetUnsupported(feature);
    }
  }

  std::cout << "[v8dasm] forced CpuFeatures::supported_=0x"
            << std::hex << forced << std::dec << "\n";
}

// Compatibility with v8 versions that have different ScriptOrigin constructors
template <typename... Args>
ScriptOrigin CreateScriptOrigin(Args&&... args) {
  if constexpr (std::is_constructible_v<ScriptOrigin, Args...>) {
      return ScriptOrigin(std::forward<Args>(args)...);
  } else {
      return ScriptOrigin(isolate, std::forward<Args>(args)...);
  }
}

static void loadBytecode(uint8_t* bytecodeBuffer, int length) {
  std::cout << "[v8dasm] cached data size: " << length << " bytes\n";
  const uint32_t cache_magic = readU32LE(bytecodeBuffer, length, 0);
  const uint32_t cache_version_hash = readU32LE(bytecodeBuffer, length, 4);
  const uint32_t cache_source_hash = readU32LE(bytecodeBuffer, length, 8);
  const uint32_t cache_flag_hash = readU32LE(bytecodeBuffer, length, 12);
  const uint32_t cache_ro_checksum = readU32LE(bytecodeBuffer, length, 16);
  const uint32_t cache_payload_length = readU32LE(bytecodeBuffer, length, 20);
  const uint32_t source_length = cache_source_hash & 0x7fffffffU;
  const bool is_module = (cache_source_hash & 0x80000000U) != 0;
  std::cout << "[v8dasm] header magic=0x" << std::hex << cache_magic
            << " version_hash=0x" << cache_version_hash
            << " source_hash=0x" << cache_source_hash
            << " flag_hash=0x" << cache_flag_hash
            << " ro_checksum=0x" << cache_ro_checksum
            << std::dec << " payload_length=" << cache_payload_length
            << " source_length=" << source_length
            << " is_module=" << (is_module ? 1 : 0) << "\n";
  std::cout << "[v8dasm] creating CachedData\n" << std::flush;

  auto* i_isolate = reinterpret_cast<v8::internal::Isolate*>(isolate);
  v8::internal::AlignedCachedData cached_data(bytecodeBuffer, length);
  v8::internal::Handle<v8::internal::String> source =
      i_isolate->factory()
          ->NewStringFromUtf8(v8::base::CStrVector("source"))
          .ToHandleChecked();
  v8::ScriptOriginOptions origin_options(false, false, false, is_module);

  std::cout << "[v8dasm] CodeSerializer::Deserialize begin\n" << std::flush;
  v8::internal::MaybeHandle<v8::internal::SharedFunctionInfo> maybe_fun =
      v8::internal::CodeSerializer::Deserialize(i_isolate, &cached_data, source,
                                                origin_options);
  v8::internal::Handle<v8::internal::SharedFunctionInfo> fun;
  const bool deserialize_empty = !maybe_fun.ToHandle(&fun);
  std::cout << "[v8dasm] CodeSerializer::Deserialize end\n" << std::flush;
  if (deserialize_empty) {
    std::cout << "[v8dasm] deserialize returned empty"
              << ", rejected=" << cached_data.rejected() << "\n";
  } else {
    std::cout << "[v8dasm] deserialize returned SharedFunctionInfo"
              << ", rejected=" << cached_data.rejected() << "\n";
  }
}

static bool readAllBytes(const std::string& file, std::vector<char>& buffer) {
  std::ifstream infile(file, std::ios::binary);
  if (!infile) {
    std::cerr << "[v8dasm] failed to open input: " << file << "\n";
    return false;
  }

  infile.seekg(0, infile.end);
  size_t length = infile.tellg();
  infile.seekg(0, infile.beg);

  if (length > 0) {
    buffer.resize(length);
    infile.read(&buffer[0], length);
  }
  return true;
}

int main(int argc, char* argv[]) {
  if (argc < 2) {
    std::cerr << "usage: " << argv[0] << " <input.v8cache>\n";
    return 2;
  }

  const char* default_flags = std::getenv("V8DASM_DEFAULT_FLAGS");
  if (default_flags != nullptr && default_flags[0] != '\0') {
    V8::SetFlagsFromString(default_flags);
    std::cout << "[v8dasm] default flags: " << default_flags << "\n";
  }
  const char* extra_flags = std::getenv("V8DASM_EXTRA_FLAGS");
  if (extra_flags != nullptr && extra_flags[0] != '\0') {
    V8::SetFlagsFromString(extra_flags);
    std::cout << "[v8dasm] extra flags: " << extra_flags << "\n";
  }

  V8::InitializeICU();
  std::unique_ptr<Platform> platform = platform::NewDefaultPlatform();
  V8::InitializePlatform(platform.get());
  V8::Initialize();
  applyCpuFeaturesOverrideFromEnv();

  const uint32_t version_tag = ScriptCompiler::CachedDataVersionTag();
  const uint32_t flag_hash = v8::internal::FlagList::Hash();
  const uint32_t cpu_features = v8::internal::CpuFeatures::SupportedFeatures();
  std::cout << "[v8dasm] CachedDataVersionTag=0x"
            << std::hex << version_tag << std::dec << "\n";
  std::cout << "[v8dasm] FlagList::Hash=0x"
            << std::hex << flag_hash << std::dec << "\n";
  std::cout << "[v8dasm] CpuFeatures::SupportedFeatures=0x"
            << std::hex << cpu_features << std::dec << "\n";
  std::cout << std::flush;
  const char* print_flag_values = std::getenv("V8DASM_PRINT_FLAG_VALUES");
  if (print_flag_values != nullptr && print_flag_values[0] != '\0') {
    std::cout << "[v8dasm] FlagList::PrintValues begin\n";
    v8::internal::FlagList::PrintValues();
    std::cout << "[v8dasm] FlagList::PrintValues end\n";
  }

  Isolate::CreateParams create_params;
  create_params.array_buffer_allocator =
      ArrayBuffer::Allocator::NewDefaultAllocator();

  isolate = Isolate::New(create_params);
  Isolate::Scope isolate_scope(isolate);
  HandleScope handle_scope(isolate);
  Local<v8::Context> context = Context::New(isolate);
  Context::Scope context_scope(context);

  std::vector<char> data;
  if (!readAllBytes(argv[1], data)) {
    return 2;
  }
  if (data.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
    std::cerr << "[v8dasm] input too large: " << data.size() << " bytes\n";
    return 2;
  }
  loadBytecode((uint8_t*)data.data(), static_cast<int>(data.size()));
}
