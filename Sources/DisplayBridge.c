#include "DisplayBridge.h"
#include <ColorSync/ColorSync.h>
#include <dlfcn.h>
#include <pthread.h>

typedef CGError (*ConfigureEnabled)(CGDisplayConfigRef, CGDirectDisplayID, bool);
static ConfigureEnabled configureEnabled;
static pthread_once_t initialization = PTHREAD_ONCE_INIT;

static void initializeBackend(void) {
    // 动态探测非公开接口，系统移除它时仍可启动并给出提示。
    void *framework = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL);
    if (framework) configureEnabled = (ConfigureEnabled)dlsym(framework, "CGSConfigureDisplayEnabled");
}

bool DOSBackendAvailable(void) {
    pthread_once(&initialization, initializeBackend);
    return configureEnabled != NULL;
}

DOSResult DOSSetDisplayEnabled(uint32_t displayID, bool enabled) {
    if (!DOSBackendAvailable()) return (DOSResult){kCGErrorNotImplemented, 1};
    CGDisplayConfigRef configuration = NULL;
    CGError error = CGBeginDisplayConfiguration(&configuration);
    if (error != kCGErrorSuccess || !configuration) return (DOSResult){error ? error : kCGErrorFailure, 2};
    error = configureEnabled(configuration, displayID, enabled);
    if (error != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(configuration);
        return (DOSResult){error, 3};
    }
    // 仅影响当前登录会话；退出工具主动恢复，避免跨登录留下关闭状态。
    error = CGCompleteDisplayConfiguration(configuration, kCGConfigureForSession);
    return (DOSResult){error, error == kCGErrorSuccess ? 0 : 4};
}

bool DOSCopyDisplayUUID(uint32_t displayID, char *buffer, long capacity) {
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(displayID);
    if (!uuid) return false;
    CFStringRef value = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    bool success = value && CFStringGetCString(value, buffer, capacity, kCFStringEncodingUTF8);
    if (value) CFRelease(value);
    CFRelease(uuid);
    return success;
}

uint32_t DOSDisplayIDForUUID(const char *text) {
    CFStringRef value = CFStringCreateWithCString(kCFAllocatorDefault, text, kCFStringEncodingUTF8);
    if (!value) return kCGNullDirectDisplay;
    CFUUIDRef uuid = CFUUIDCreateFromString(kCFAllocatorDefault, value);
    CFRelease(value);
    if (!uuid) return kCGNullDirectDisplay;
    uint32_t displayID = CGDisplayGetDisplayIDFromUUID(uuid);
    CFRelease(uuid);
    return displayID;
}
