// main.c

#include <stdio.h>
#include "reel.h"

static int (*original_printf)(const char * __restrict, ...);

int my_printf(const char *format, ...) {
    original_printf("[HOOKED] ");
    va_list args;
    va_start(args, format);
    int result = vprintf(format, args);
    va_end(args);
    
    return result;
}

int main(int argc, const char * argv[]) {
    printf("About to hook printf...\n");

    struct rebinding printf_rebinding = {
        .name = "printf",
        .replacement = my_printf,
        .original = (void**)&original_printf
    };
    
    rebind_symbols(&printf_rebinding, 1);
    
    printf("Hello, hooked world!\n");
    printf("The hook seems to be working! %d %d %d\n", 1, 2, 3);
    
    if (original_printf) {
        original_printf("This is a direct call to the original printf.\n");
    }
    
    return 0;
}
