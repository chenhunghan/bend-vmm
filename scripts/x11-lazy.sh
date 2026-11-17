#!/usr/bin/env bash
# Rewrites a C file that `bend -o x.c` emitted on Linux so it needs no
# libX11 at link or load time: every Xlib function it calls goes through a
# pointer that the first XOpenDisplay fills from a dlopen'd libX11.so.6 (as
# Bend's window runtime already does for libXrender, libXrandr and libXi).
# Without libX11 (a headless server), XOpenDisplay returns NULL and
# Window.open fails as it does with no display; nothing else changes.
#   scripts/x11-lazy.sh <file.c>
set -euo pipefail
c=$1
anchor='#include <X11/keysym.h>'
grep -qxF "$anchor" "$c" || exit 0   # no window runtime: nothing to do
cc=${CC:-clang}
hdrs=$'#include <X11/Xlib.h>\n#include <X11/Xatom.h>\n#include <X11/Xutil.h>\n#include <X11/keysym.h>'
macros=$(printf '%s\n' "$hdrs" | "$cc" -dM -E -x c - | awk '{ sub(/\(.*/, "", $2); print $2 }' | sort -u)
decls=$(printf '%s\n' "$hdrs" | "$cc" -E -P -x c - | tr -s ' \t\n' ' ')
names=()
for n in $(grep -oE '\bX[A-Za-z0-9_]+ *\(' "$c" | tr -d ' (' | sort -u); do
  grep -qxF "$n" <<<"$macros" && continue          # a macro (XDestroyImage)
  grep -qE "extern[^;(]*[ *]$n ?\(" <<<"$decls" || continue   # not an Xlib function (XID)
  names+=("$n")
done
printf '%s\n' "${names[@]}" | grep -qx XOpenDisplay || { echo "x11-lazy: no XOpenDisplay in $c" >&2; exit 1; }
h=$(mktemp)
{
  echo '// scripts/x11-lazy.sh: Xlib through pointers, loaded by the first XOpenDisplay.'
  for n in "${names[@]}"; do echo "static __typeof__($n) *bx11_$n;"; done
  echo 'static Display* bx11_none(_Xconst char* name) { (void)name; return NULL; }'
  echo 'static __typeof__(XOpenDisplay) *bx11_open(void) {'
  echo '  if (bx11_XOpenDisplay != NULL) return bx11_XOpenDisplay;'
  echo '  void* lib = dlopen("libX11.so.6", RTLD_LAZY | RTLD_GLOBAL);'
  echo '  if (lib == NULL) return bx11_none;'
  for n in "${names[@]}"; do
    [ "$n" = XOpenDisplay ] && continue
    echo "  if ((bx11_$n = (__typeof__($n) *)dlsym(lib, \"$n\")) == NULL) return bx11_none;"
  done
  echo '  bx11_XOpenDisplay = (__typeof__(XOpenDisplay) *)dlsym(lib, "XOpenDisplay");'
  echo '  return bx11_XOpenDisplay != NULL ? bx11_XOpenDisplay : bx11_none;'
  echo '}'
  for n in "${names[@]}"; do
    [ "$n" = XOpenDisplay ] && echo '#define XOpenDisplay (*bx11_open())' || echo "#define $n (*bx11_$n)"
  done
} > "$h"
# The pointers go right after Xlib's headers (and <dlfcn.h>, which follows them).
awk -v anchor="$anchor" -v h="$h" '
  { print }
  $0 == anchor { print "#include <dlfcn.h>"; while ((getline l < h) > 0) print l }
' "$c" > "$c.lazy" && mv "$c.lazy" "$c"
rm -f "$h"
