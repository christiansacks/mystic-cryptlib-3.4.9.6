#!/usr/bin/env bash
#
# Build Cryptlib 3.4.9.6 and the compatibility shim for Mystic BBS on
# 32-bit Windows, cross-compiling on Linux with MinGW-w64.
#
# Output (in ./dist/win32):
#   cl32.dll    the shim - Mystic loads this.  It translates the Cryptlib
#               3.4.5 constants Mystic has compiled in and forwards to:
#   cl349.dll   Cryptlib 3.4.9.6 (AES-CTR etc. enabled)
#   cltest.exe  quick check you can run on the Windows box
#
# Needs: gcc-mingw-w64-i686 (i686-w64-mingw32-gcc), make, patch, git.
#   Debian/Ubuntu:  sudo apt install gcc-mingw-w64-i686 make patch git
#
# Uses ../payload/maps.h and ../payload/ssh-ctr-ed25519.patch from the Linux
# installer, plus the Windows files in ./payload.

set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$HERE/.." && pwd)"
CRYPTLIB_REPO="https://github.com/cryptlib/cryptlib"
CRYPTLIB_COMMIT="6d94f880897ceaa1f833a2f94df51321f983b87e"   # 3.4.9.6
CC=i686-w64-mingw32-gcc
OUT="$HERE/dist/win32"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mystic-cl-win.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

die() { echo "error: $*" >&2; exit 1; }
command -v $CC >/dev/null || die "$CC not found (apt install gcc-mingw-w64-i686)"

echo "==> Getting Cryptlib ${CRYPTLIB_COMMIT:0:10}"
SRC="$WORK/cryptlib"
git init -q "$SRC"
git -C "$SRC" fetch -q --depth 1 "$CRYPTLIB_REPO" "$CRYPTLIB_COMMIT"
git -C "$SRC" checkout -q FETCH_HEAD
[ "$(git -C "$SRC" rev-parse HEAD)" = "$CRYPTLIB_COMMIT" ] || die "wrong commit"

echo "==> Patching"
( cd "$SRC"
  patch -p1 -s < "$TOP/payload/ssh-ctr-ed25519.patch"
  patch -p1 -s < "$HERE/payload/ssh-auth-unoffered-method.patch" )

echo "==> Building Cryptlib (a few minutes)"
mkdir -p "$WORK/inc" "$SRC/static-obj"
cp "$HERE/payload/endian.h" "$WORK/inc/"
# target-init: make the tool scripts executable and switch the makefile from
# random/unix.c to random/win32.c (Windows entropy source)
( cd "$SRC" && make -s OSNAME=win32 target-init >/dev/null )
SEED="$(cd "$SRC" && sh ./tools/getseed.sh Linux)"
# -mincoming-stack-boundary=2: Mystic (Free Pascal) calls DLLs with the stack
#   only 4-byte aligned; without this cryptInit fails with -16 (internal
#   error) and Mystic says "Cryptlib not detected".
# -DNO_ASM: the x86 assembler code is MSVC-only.
CFLAGS="-c -I. -I$WORK/inc -DNDEBUG -O2 -march=i686 -mtune=generic -mincoming-stack-boundary=2 \
 -D__WINDOWS__ -DCONFIG_DATA_LITTLEENDIAN -DOSVERSION=7 -DNO_ASM $SEED -Wno-pointer-sign"
# The library objects build; the self-test objects don't under MinGW and
# aren't needed, so -k and check the objects afterwards.
( cd "$SRC" && make -k -j"$(nproc)" libcl.a OBJPATH=./static-obj/ CROSSCOMPILE=1 OSNAME=win32 \
    CC=$CC AR=i686-w64-mingw32-ar CFLAGS="$CFLAGS" >"$WORK/build.log" 2>&1 ) || true
cat > "$WORK/objs.mk" <<'MK'
include makefile
printobjs:
	@echo $(OBJS)
MK
MISSING=0
for o in $(cd "$SRC" && make -s -f "$WORK/objs.mk" printobjs OBJPATH=./static-obj/ OSNAME=win32); do
	[ -f "$SRC/$o" ] || { echo "missing $o" >&2; MISSING=1; }
done
[ $MISSING = 0 ] || { tail -30 "$WORK/build.log"; die "Cryptlib objects failed to build"; }

echo "==> Linking cl349.dll"
mkdir -p "$OUT"
$CC -c -O2 -march=i686 -mincoming-stack-boundary=2 -o "$WORK/compat.o" "$HERE/payload/compat.c"
$CC -shared -o "$OUT/cl349.dll" "$SRC"/static-obj/*.o "$WORK/compat.o" -Wl,--kill-at -static-libgcc \
    -lws2_32 -ladvapi32 -lnetapi32 -luser32 -lcrypt32
echo "==> Building the shim cl32.dll and cltest.exe"
cp "$TOP/payload/maps.h" "$WORK/"
$CC -O2 -Wall -march=i686 -mincoming-stack-boundary=2 -shared -I"$WORK" -o "$OUT/cl32.dll" \
    "$HERE/payload/shim-win.c" -Wl,--kill-at -static-libgcc
$CC -O1 -march=i686 -o "$OUT/cltest.exe" "$HERE/payload/cltest.c" -static-libgcc
i686-w64-mingw32-strip "$OUT"/*.dll "$OUT/cltest.exe"

echo "==> Checking"
for f in aes128-ctr aes256-ctr; do grep -qa "$f" "$OUT/cl349.dll" || die "$f missing from cl349.dll"; done
for f in cryptInit cryptEnd cryptAddRandom cryptCreateContext cryptDestroyContext cryptGenerateKey \
         cryptEncrypt cryptDecrypt cryptCreateCert cryptDestroyCert cryptSignCert cryptKeysetOpen \
         cryptKeysetClose cryptGetPublicKey cryptGetPrivateKey cryptAddPublicKey cryptAddPrivateKey \
         cryptCreateSession cryptDestroySession cryptSetAttribute cryptSetAttributeString \
         cryptGetAttribute cryptGetAttributeString cryptPushData cryptPopData cryptFlushData; do
	grep -qa "$f" "$OUT/cl32.dll" || die "shim does not export $f"
done
echo
echo "Done: $OUT"
ls -l "$OUT"
echo
echo "Install: stop Mystic, rename cl32.dll to cl32.dll.pre-349, copy cl32.dll and"
echo "cl349.dll into the Mystic folder, start Mystic.  See windows/README.md."
