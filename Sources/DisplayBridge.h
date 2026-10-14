#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

typedef struct {
    int32_t code;
    int32_t stage; /* 0 成功；1 不支持；2 开始；3 设置；4 提交 */
} DOSResult;

bool DOSBackendAvailable(void);
DOSResult DOSSetDisplayEnabled(uint32_t displayID, bool enabled);
bool DOSCopyDisplayUUID(uint32_t displayID, char *buffer, long capacity);
uint32_t DOSDisplayIDForUUID(const char *uuid);
