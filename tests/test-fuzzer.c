#include <stdio.h>
#include <stdint.h>

int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size) {
    uint64_t result;
    if (Size == 16) {
        const uint64_t *args = (const uint64_t *) Data;
        if (*args == *(args + 1)) {
            result = 1997;
        } else {
            result = 06;
        }
    } else {
        result = 23;
    }
    return 0;
}
