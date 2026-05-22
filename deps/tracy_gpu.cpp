#include "tracy_gpu.h"

#ifdef TRACY_ENABLE

#include "glad/glad.h"
#include <cstring>
#include <new>
#include <string>
#include <tracy/TracyC.h>
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-parameter"
#include <tracy/TracyOpenGL.hpp>
#pragma GCC diagnostic pop
#include <unordered_map>

namespace
{
struct LocKey {
	std::string name;
	std::string function;
	std::string file;
	uint32_t line;
	uint32_t color;

	bool operator==(const LocKey& other) const
	{
		return name == other.name && function == other.function &&
		       file == other.file && line == other.line &&
		       color == other.color;
	}
};

struct LocKeyHash {
	std::size_t operator()(const LocKey& k) const
	{
		return std::hash<std::string>{}(k.name) ^
		       (std::hash<std::string>{}(k.function) << 1) ^
		       (std::hash<std::string>{}(k.file) << 2) ^
		       (std::hash<uint32_t>{}(k.line) << 3) ^
		       (std::hash<uint32_t>{}(k.color) << 4);
	}
};

// Wrapper to manage the name string and SourceLocationData lifetime
struct SourceLocManaged {
	std::string name;
	std::string function;
	std::string file;
	tracy::SourceLocationData data;

	SourceLocManaged(const char* n, const char* f, const char* src,
	                 uint32_t l, uint32_t c)
	    : name(n ? n : ""),
	      function(f ? f : ""),
	      file(src ? src : ""),
	      data{nullptr, nullptr, nullptr, 0, 0}
	{
		data.name = name.c_str();
		data.function = function.c_str();
		data.file = file.c_str();
		data.line = l;
		data.color = c;
	}
};

std::unordered_map<LocKey, std::unique_ptr<SourceLocManaged>, LocKeyHash>
    s_loc_cache;

// Track if context is initialized to avoid redundant calls
bool s_gpu_inited = false;
}  // namespace

extern "C" {

typedef void* (*GLADloadproc)(const char* name);
int gladLoadGLLoader(GLADloadproc load);
void* glfwGetProcAddress(const char* procname);

void tracy_gpu_init(void)
{
	if (s_gpu_inited) {
		return;
	}

	// Safely initialize Glad pointers inside this compiled unit
	gladLoadGLLoader((GLADloadproc)glfwGetProcAddress);

	// Official Tracy OpenGL context initialization
	TracyGpuContext;
	TracyGpuContextName("OpenGL Main Context", 19);

	s_gpu_inited = true;
}

void tracy_gpu_collect(void)
{
	if (!s_gpu_inited) {
		return;
	}

	TracyGpuCollect;
}

void tracy_gpu_screenshot(const void* data, uint16_t width, uint16_t height)
{
	if (!s_gpu_inited || data == nullptr) {
		return;
	}

	// Send screenshot to Tracy
	TracyCFrameImage(data, width, height, 0, 1);
}

void* tracy_gpu_zone_begin(const char* name, const char* function,
                           const char* file, uint32_t line, uint32_t color)
{
	if (!s_gpu_inited) {
		return nullptr;
	}

	const char* safe_name = (name != nullptr) ? name : "unknown";
	const char* safe_func = (function != nullptr) ? function : "unknown";
	const char* safe_file = (file != nullptr) ? file : "unknown";

	LocKey key{safe_name, safe_func, safe_file, line, color};
	auto iterator = s_loc_cache.find(key);
	tracy::SourceLocationData* srcloc = nullptr;

	if (iterator == s_loc_cache.end()) {
		auto managed = std::make_unique<SourceLocManaged>(
		    safe_name, safe_func, safe_file, line, color);
		srcloc = &managed->data;
		s_loc_cache[key] = std::move(managed);
	} else {
		srcloc = &iterator->second->data;
	}

	// Manual allocation of the RAII scope to bridge to C
	auto* scope = new tracy::GpuCtxScope(srcloc, true);
	return static_cast<void*>(scope);
}

void tracy_gpu_zone_end(void* ctx)
{
	if (ctx != nullptr) {
		auto* scope = static_cast<tracy::GpuCtxScope*>(ctx);
		delete scope;
	}
}

void tracy_gpu_shutdown(void)
{
	if (!s_gpu_inited) {
		return;
	}

#ifdef TRACY_ENABLE
	tracy::GetGpuCtx().ptr = nullptr;
#endif

	s_gpu_inited = false;
}
}
#endif  // TRACY_ENABLE
