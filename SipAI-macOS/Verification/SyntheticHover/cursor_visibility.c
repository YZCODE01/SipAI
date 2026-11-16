// Answers CGCursorIsVisible from $HARNESS_CURSOR_VISIBLE ("1" visible, "0" hidden), so a harness
// can put macOS's answer either way while it runs; unset, the real answer. Preloaded
// (DYLD_INSERT_LIBRARIES) into a harness's own test program alone — cursor_visible.sh does it —
// so the real cursor is untouched. The interpose table replaces the function for every image in
// the process, SwiftUI's question to AppKit before it honours a pointer event
// (`+[NSCursor _isHidden]`) included, and a dlsym lookup of the name finds the replacement too.
#include <stdlib.h>

// Declared here rather than taken from CoreGraphics' header, which marks it deprecated.
extern int CGCursorIsVisible(void);

static int answer(void) {
    const char *visible = getenv("HARNESS_CURSOR_VISIBLE");
    return visible ? atoi(visible) : CGCursorIsVisible();
}

__attribute__((used)) static const struct {
    const void *replacement;
    const void *replacee;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)answer, (const void *)CGCursorIsVisible },
};

// Loaded, the library leaves the environment, so nothing the program starts loads it too: an
// agent CLI the app runs would inherit the preload, and kimi's single-file executable aborts
// with a library inserted into it.
__attribute__((constructor)) static void leave_the_environment(void) {
    unsetenv("DYLD_INSERT_LIBRARIES");
}
