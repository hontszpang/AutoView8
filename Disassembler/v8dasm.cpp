#include <fstream>
#include <iostream>
#include <string>
#include <cstdlib>

#include "include/v8.h"
#include "include/libplatform/libplatform.h"
#include "src/codegen/cpu-features.h"
#include "src/flags/flags.h"

using namespace v8;

static Isolate* isolate = nullptr;

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
  if constexpr (std::is_constructible_v<ScriptOrigin, Isolate*, Local<String>>) {
      return ScriptOrigin(isolate, std::forward<Args>(args)...);
  } else {
      return ScriptOrigin(std::forward<Args>(args)...);
  }
}

static void loadBytecode(uint8_t* bytecodeBuffer, int length) {
  std::cout << "[v8dasm] cached data size: " << length << " bytes\n";

  // Load code into code cache.
  ScriptCompiler::CachedData* cached_data =
      new ScriptCompiler::CachedData(bytecodeBuffer, length);

  // Create dummy source.
  ScriptOrigin origin = CreateScriptOrigin(String::NewFromUtf8Literal(isolate, "code.jsc"));

  ScriptCompiler::Source source(String::NewFromUtf8Literal(isolate, "\"ಠ_ಠ\""),
                                origin, cached_data);

  // Compile code from code cache to print disassembly.
  MaybeLocal<UnboundScript> script = ScriptCompiler::CompileUnboundScript(
      isolate, &source, ScriptCompiler::kConsumeCodeCache);
  if (script.IsEmpty()) {
    std::cout << "[v8dasm] compile returned empty script"
              << ", rejected=" << cached_data->rejected << "\n";
  } else {
    std::cout << "[v8dasm] compile returned script"
              << ", rejected=" << cached_data->rejected << "\n";
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

  V8::SetFlagsFromString(
      "--no-lazy "
      "--no-flush-bytecode "
      "--no-verify-snapshot-checksum "
      "--no-enable-lazy-source-positions");
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
  loadBytecode((uint8_t*)data.data(), data.size());
}
