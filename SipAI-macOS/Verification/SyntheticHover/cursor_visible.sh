# Sourced by the harnesses that point with a made-up pointer — NewSessionSetup,
# UsageWindow, SkillsPane, SidebarNotices, LinkPointers — and by SyntheticHover's
# own run.sh.
#
# SwiftUI honours a pointer event only while macOS reports the cursor visible,
# and macOS can report it hidden from a pointer at rest (under Screen Sharing,
# for one): a harness's made-up pointer then reaches nothing, and a check that
# needs hover fails with nothing wrong, or passes having tested nothing. So the
# test program runs with cursor_visibility.dylib preloaded, answering "visible"
# inside that program alone; the real cursor is untouched.
#
#   cursor_preload <dir>                   builds the library into <dir> and
#                                          sets CURSOR_PRELOAD
#   cursor_visible <program> [args…]       execs the program under it — call it
#                                          in a subshell
#   cursor_visible_within <s> <program> …  the same, ended after <s> seconds

cursor_preload() {
  CURSOR_PRELOAD="$1/cursor_visibility.dylib"
  xcrun clang -dynamiclib -O2 -framework CoreGraphics -o "$CURSOR_PRELOAD" \
    "$(dirname "${BASH_SOURCE[0]}")/cursor_visibility.c"
}

cursor_visible() {
  export DYLD_INSERT_LIBRARIES="$CURSOR_PRELOAD" HARNESS_CURSOR_VISIBLE=1
  exec "$@"
}

# perl ends the run, and perl is a system binary: macOS strips DYLD_* from a
# system binary's environment, so the library is named inside perl, just before
# the program starts.
cursor_visible_within() {
  local seconds="$1"
  shift
  HARNESS_CURSOR_VISIBLE=1 perl -e '$ENV{DYLD_INSERT_LIBRARIES} = shift; alarm shift; exec @ARGV' \
    "$CURSOR_PRELOAD" "$seconds" "$@"
}
