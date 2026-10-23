#!/usr/bin/env bash
#
# Modern SSH for Mystic BBS: build and install a current Cryptlib plus a
# compatibility shim.
#
# Mystic does all of its SSH through Cryptlib (libs/libcl.so).  Out of the box
# that is an old Cryptlib with CBC-only ciphers.  Current Cryptlib can't just be
# dropped in because it renumbered constants that Mystic hard-codes, and its
# default build needs a CPU with AVX2.  This script:
#
#   1. downloads the pinned Cryptlib source,
#   2. patches it (AES-CTR, curve25519/ed25519, baseline-CPU build),
#   3. builds it and a small translation shim,
#   4. self-tests both, and
#   5. optionally installs them into a Mystic directory (with a backup).
#
# Run with --help for options.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$SCRIPT_DIR/payload"

CRYPTLIB_REPO="https://github.com/cryptlib/cryptlib"
CRYPTLIB_COMMIT="6d94f880897ceaa1f833a2f94df51321f983b87e"   # 3.4.9.6
CRYPTLIB_VERSION_EXPECT="349"
TESTED_MYSTIC="A49"

MYSTIC_FUNCS="cryptInit cryptEnd cryptAddRandom cryptCreateContext cryptDestroyContext
 cryptGenerateKey cryptEncrypt cryptDecrypt cryptCreateCert cryptDestroyCert cryptSignCert
 cryptKeysetOpen cryptKeysetClose cryptGetPublicKey cryptGetPrivateKey cryptAddPublicKey
 cryptAddPrivateKey cryptCreateSession cryptDestroySession cryptSetAttribute
 cryptSetAttributeString cryptGetAttribute cryptGetAttributeString cryptPushData
 cryptPopData cryptFlushData"

# ---- options ----------------------------------------------------------------
MYSTIC_DIR=""
BUILD_DIR=""
OUT_DIR=""
SOURCE_DIR=""
DO_INSTALL=1
INSTALL_ONLY=0
RESTORE=0
ASSUME_YES=0
USE_UI=1
KEEP_BUILD=0

BUILD_TMP=""        # set only for a build dir that we created ourselves
UI=""               # whiptail | dialog | prompt | none

usage() {
	cat <<EOF
Usage: $0 [options]

Builds Cryptlib ${CRYPTLIB_VERSION_EXPECT:0:1}.${CRYPTLIB_VERSION_EXPECT:1:1}.${CRYPTLIB_VERSION_EXPECT:2:1} and the Mystic compatibility shim, then (optionally)
installs them into a Mystic directory.

  -d, --mystic-dir DIR   Mystic directory to install into (the one with mis, mystic,
                         mystic.dat).  If omitted you are asked (whiptail, dialog or
                         a plain prompt, in that order of preference).
      --no-install       Build and test only; leave the result in the output dir.
      --install-only     Skip the build; install from an earlier build's output dir.
      --restore          Put back the original libcl.so (from the backup) in DIR.
  -o, --output-dir DIR   Where finished files go (default: ./dist/<arch> next to
                         this script).
  -b, --build-dir DIR    Work directory for the build (default: a fresh temp dir).
      --keep-build       Don't delete the temp build dir afterwards.
      --source DIR       Use an already-downloaded Cryptlib source tree (offline
                         builds).  It must be version 3.4.9 and unpatched.
  -y, --yes              Don't ask for confirmation.
      --no-ui            Never use whiptail/dialog; plain prompts only.
  -h, --help             This text.

Nothing in the Mystic directory is touched until the build and self-test pass.
After installing, restart mis (for example: systemctl restart mystic-bbs.service).
EOF
}

# ---- helpers ----------------------------------------------------------------
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_off=$'\033[0m'
[ -t 2 ] || { c_red=""; c_grn=""; c_ylw=""; c_off=""; }

msg()  { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%swarning:%s %s\n' "$c_ylw" "$c_off" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
	local rc=$?
	if [ -n "$BUILD_TMP" ] && [ -d "$BUILD_TMP" ] && [[ "$BUILD_TMP" == */mystic-ssh-build.* ]]; then
		if [ "$rc" -ne 0 ]; then
			warn "build directory kept for inspection: $BUILD_TMP"
		elif [ "$KEEP_BUILD" -eq 1 ]; then
			msg "Build directory kept: $BUILD_TMP"
		else
			rm -rf -- "$BUILD_TMP"
		fi
	fi
	exit "$rc"
}
trap cleanup EXIT

# ---- user interface (whiptail / dialog / prompt) ------------------------------
pick_ui() {
	UI="prompt"
	if [ ! -t 0 ] || [ ! -t 1 ]; then UI="none"; return; fi
	[ "$USE_UI" -eq 1 ] || return 0
	if have whiptail; then UI="whiptail"
	elif have dialog; then UI="dialog"
	fi
}

# ui_input TITLE TEXT DEFAULT  -> prints the answer; returns 1 if cancelled
ui_input() {
	local title="$1" text="$2" def="${3:-}" ans
	case "$UI" in
	whiptail) whiptail --title "$title" --inputbox "$text" 12 72 "$def" 3>&1 1>&2 2>&3 ;;
	dialog)   dialog --stdout --title "$title" --inputbox "$text" 12 72 "$def" ;;
	prompt)
		printf '%b\n' "$text" >&2
		read -r -p "[${def}] > " ans || return 1
		printf '%s\n' "${ans:-$def}" ;;
	*) return 1 ;;
	esac
}

# ui_yesno TITLE TEXT  -> returns 0 for yes
ui_yesno() {
	local title="$1" text="$2" ans
	[ "$ASSUME_YES" -eq 1 ] && return 0
	[ "$UI" != "none" ] || die "not running on a terminal; add -y to install without confirmation"
	case "$UI" in
	whiptail) whiptail --title "$title" --yesno "$text" 18 72 ;;
	dialog)   dialog --title "$title" --yesno "$text" 18 72 ;;
	prompt)
		printf '\n%b\n' "$text" >&2
		read -r -p "Continue? [y/N] " ans || return 1
		[[ "$ans" =~ ^[Yy] ]] ;;
	*) return 1 ;;
	esac
}

# ---- preflight --------------------------------------------------------------
HOST_ARCH=""
preflight() {
	step "Checking the build environment"
	[ "$(uname -s)" = "Linux" ] || die "only Linux is supported (found $(uname -s))"
	HOST_ARCH="$(uname -m)"
	msg "Host: Linux $HOST_ARCH"

	local missing=() t
	for t in make patch tar sha256sum awk grep; do have "$t" || missing+=("$t"); done
	have gcc || have cc || missing+=("gcc")
	if [ -z "$SOURCE_DIR" ]; then
		have git || { have curl || have wget || missing+=("git (or curl/wget)"); }
	fi
	# zlib headers
	if have gcc || have cc; then
		local cc; cc="$(have gcc && echo gcc || echo cc)"
		printf '#include <zlib.h>\n' | "$cc" -x c -E - >/dev/null 2>&1 ||
			missing+=("zlib development headers (zlib1g-dev / zlib-devel)")
	fi
	if [ "${#missing[@]}" -gt 0 ]; then
		printf '%s\n' "Missing tools: ${missing[*]}" >&2
		msg "Install them, for example:" >&2
		msg "  Debian/Ubuntu:  sudo apt install build-essential patch git zlib1g-dev" >&2
		msg "  Fedora/RHEL:    sudo dnf install gcc make patch git zlib-devel" >&2
		msg "  Arch:           sudo pacman -S base-devel git zlib" >&2
		exit 1
	fi
	have objdump || warn "objdump not found: the CPU-instruction check will be skipped"
	for t in "$PAYLOAD/shim.c" "$PAYLOAD/maps.h" "$PAYLOAD/shimtest.c" \
	         "$PAYLOAD/ssh-ctr-ed25519.patch" "$PAYLOAD/ccopts-baseline-x86-64.patch"; do
		[ -f "$t" ] || die "installer payload incomplete, missing $t"
	done
}

# ---- fetch + patch + build --------------------------------------------------
fetch_source() {
	local dest="$1"
	step "Getting Cryptlib source (commit ${CRYPTLIB_COMMIT:0:10})"
	mkdir -p "$dest"
	if [ -n "$SOURCE_DIR" ]; then
		[ -f "$SOURCE_DIR/cryptlib.h" ] || die "--source: $SOURCE_DIR doesn't look like a Cryptlib tree"
		cp -a "$SOURCE_DIR/." "$dest/"
	elif have git; then
		git -C "$dest" init -q
		git -C "$dest" fetch -q --depth 1 "$CRYPTLIB_REPO" "$CRYPTLIB_COMMIT" ||
			die "couldn't download Cryptlib from $CRYPTLIB_REPO (network?)"
		git -C "$dest" checkout -q FETCH_HEAD
		local got; got="$(git -C "$dest" rev-parse HEAD)"
		[ "$got" = "$CRYPTLIB_COMMIT" ] || die "downloaded commit $got, expected $CRYPTLIB_COMMIT"
		msg "Verified commit $got"
	else
		local url="$CRYPTLIB_REPO/archive/$CRYPTLIB_COMMIT.tar.gz"
		msg "git not found, using the tarball ($url)"
		if have curl; then curl -fsSL "$url" | tar -xz --strip-components=1 -C "$dest"
		else wget -qO- "$url" | tar -xz --strip-components=1 -C "$dest"
		fi || die "couldn't download Cryptlib"
	fi
	local ver
	ver="$(awk '/^#define[ \t]+CRYPTLIB_VERSION[ \t]/ {print $3; exit}' "$dest/cryptlib.h" 2>/dev/null || true)"
	[ "$ver" = "$CRYPTLIB_VERSION_EXPECT" ] ||
		die "Cryptlib source reports version '$ver', this installer is built for $CRYPTLIB_VERSION_EXPECT"
	msg "Cryptlib version $ver OK"
}

patch_source() {
	local src="$1"
	step "Patching Cryptlib"
	( cd "$src"
	  patch -p1 --dry-run -s < "$PAYLOAD/ssh-ctr-ed25519.patch" >/dev/null ||
		die "ssh-ctr-ed25519.patch does not apply (source differs from the pinned commit?)"
	  patch -p1 -s < "$PAYLOAD/ssh-ctr-ed25519.patch"
	  msg "Applied: AES-CTR + curve25519 + ed25519 for SSH, CTR advertisement fix"
	  if [ "$HOST_ARCH" = "x86_64" ]; then
		patch -p1 --dry-run -s < "$PAYLOAD/ccopts-baseline-x86-64.patch" >/dev/null ||
			die "ccopts-baseline-x86-64.patch does not apply"
		patch -p1 -s < "$PAYLOAD/ccopts-baseline-x86-64.patch"
		msg "Applied: baseline x86-64 build (no AVX2/BMI2 requirement)"
	  else
		msg "Skipped: x86-64 CPU baseline patch (not needed on $HOST_ARCH)"
	  fi )
}

build_cryptlib() {
	local src="$1" jobs
	jobs="$(nproc 2>/dev/null || echo 2)"
	step "Building Cryptlib (a few minutes; log: $src/build.log)"
	( cd "$src" && make shared -j"$jobs" >build.log 2>&1 ) || {
		tail -25 "$src/build.log" >&2
		die "Cryptlib build failed (full log: $src/build.log)"
	}
	local lib; lib="$(ls "$src"/libcl.so.3.4.* 2>/dev/null | head -1 || true)"
	[ -n "$lib" ] && [ -f "$lib" ] || die "build finished but libcl.so.3.4.* is missing"
	REAL_LIB="$lib"
	msg "Built $(basename "$lib")"
}

verify_real_lib() {
	step "Verifying the Cryptlib build"
	local f missing=()
	if have nm; then
		for f in $MYSTIC_FUNCS; do
			nm -D --defined-only "$REAL_LIB" 2>/dev/null | awk '{print $3}' | grep -qx "$f" || missing+=("$f")
		done
		[ "${#missing[@]}" -eq 0 ] || die "library is missing functions Mystic needs: ${missing[*]}"
		msg "All $(printf '%s\n' $MYSTIC_FUNCS | wc -l) Mystic entry points are exported"
	fi
	for f in aes128-ctr aes256-ctr; do
		grep -qa "$f" "$REAL_LIB" || die "library does not contain the $f cipher (patch not effective?)"
	done
	msg "AES-CTR ciphers present"
	if [ "$HOST_ARCH" = "x86_64" ] && have objdump; then
		local n
		n="$(objdump -d "$REAL_LIB" 2>/dev/null | grep -cE '\b(vpxor|vmovdqu|vmovdqa|vzeroupper|vpaddq|vpand|rorx|mulx|andn|shlx|shrx|sarx|tzcnt|lzcnt|bextr)\b' || true)"
		[ "${n:-0}" -eq 0 ] ||
			die "library contains $n AVX/BMI instructions and would crash on CPUs without them (build flags not applied?)"
		msg "No AVX/BMI instructions: runs on any x86-64 CPU"
	fi
}

build_shim() {
	local work="$1" cc
	cc="$(have gcc && echo gcc || echo cc)"
	step "Building the compatibility shim"
	cp "$PAYLOAD/shim.c" "$PAYLOAD/maps.h" "$PAYLOAD/shimtest.c" "$work/"
	( cd "$work" &&
	  "$cc" -O2 -Wall -Wextra -fPIC -shared -Wl,-soname,libcl.so.3.4 -o libcl_shim.so shim.c -ldl &&
	  "$cc" -O2 -o shimtest shimtest.c -ldl ) || die "shim build failed"
	msg "Built libcl_shim.so"
}

selftest() {
	local stage="$1"
	step "Self-test"
	cp "$2" "$stage/libcl_real.so"
	cp "$3" "$stage/libcl.so"
	"$4" "$stage/libcl.so" || die "self-test failed: the shim could not initialise Cryptlib"
	msg "Shim loads, checks the version and initialises Cryptlib: OK"
}

# ---- installing -------------------------------------------------------------
detect_mystic_dir() {
	local p d
	for p in $(pgrep -x mis 2>/dev/null || true); do
		d="$(readlink -f "/proc/$p/cwd" 2>/dev/null || true)"
		[ -n "$d" ] && [ -x "$d/mis" ] && { printf '%s\n' "$d"; return; }
	done
	for d in /mystic "$HOME/mystic" /home/mystic /opt/mystic /usr/local/mystic; do
		[ -x "$d/mis" ] && [ -f "$d/mystic.dat" ] && { printf '%s\n' "$d"; return; }
	done
}

validate_mystic_dir() {
	local d="$1"
	[ -d "$d" ] || die "$d is not a directory"
	[ -x "$d/mis" ] && [ -x "$d/mystic" ] && [ -f "$d/mystic.dat" ] ||
		die "$d doesn't look like a Mystic directory (need mis, mystic and mystic.dat)"
	local ver
	ver="$(grep -aoE 'v1\.12 A[0-9]+' "$d/mis" 2>/dev/null | head -1 || true)"
	MYSTIC_VER="${ver:-unknown}"
	if [[ "$MYSTIC_VER" != *"$TESTED_MYSTIC" ]]; then
		warn "Mystic version is '$MYSTIC_VER'; this was only tested with $TESTED_MYSTIC"
		UNTESTED_NOTE=$'\n\nNOTE: this Mystic version has not been tested.'
	fi
	# CPU architecture of Mystic vs the library we built
	if have readelf; then
		local m_cls m_mach l_cls l_mach
		m_cls="$(readelf -h "$d/mis" 2>/dev/null | awk -F: '/Class:/ {gsub(/ /,"",$2); print $2}')"
		m_mach="$(readelf -h "$d/mis" 2>/dev/null | awk -F: '/Machine:/ {gsub(/^ +/,"",$2); print $2}')"
		l_cls="$(readelf -h "$OUT_DIR/libcl_real.so" 2>/dev/null | awk -F: '/Class:/ {gsub(/ /,"",$2); print $2}')"
		l_mach="$(readelf -h "$OUT_DIR/libcl_real.so" 2>/dev/null | awk -F: '/Machine:/ {gsub(/^ +/,"",$2); print $2}')"
		if [ -n "$m_cls" ] && [ -n "$l_cls" ] && { [ "$m_cls" != "$l_cls" ] || [ "$m_mach" != "$l_mach" ]; }; then
			die "Mystic is $m_cls/$m_mach but the library was built for $l_cls/$l_mach. Build on a matching system."
		fi
	fi
}

is_shim() { grep -qa 'libcl shim' "$1" 2>/dev/null; }

do_install() {
	local d="$1" libs="$1/libs" ts bak
	[ -f "$OUT_DIR/libcl.so" ] && [ -f "$OUT_DIR/libcl_real.so" ] ||
		die "nothing to install in $OUT_DIR (run without --install-only first)"
	[ -w "$d" ] || die "no write access to $d (re-run with sudo?)"
	mkdir -p "$libs"

	step "Installing into $libs"
	if [ -f "$libs/libcl.so" ] && ! is_shim "$libs/libcl.so"; then
		bak="$libs/libcl.so.bak"
		[ ! -e "$bak" ] || bak="$libs/libcl.so.bak.$(date +%Y%m%d%H%M%S)"
		cp -p "$libs/libcl.so" "$bak"
		msg "Backed up the existing library to $bak"
	elif [ -f "$libs/libcl.so" ]; then
		msg "A previous shim is installed; keeping the existing backup"
	else
		msg "No existing libs/libcl.so (Mystic had no SSH library)"
	fi
	install -m 755 "$OUT_DIR/libcl_real.so" "$libs/libcl_real.so.new"
	install -m 755 "$OUT_DIR/libcl.so" "$libs/libcl.so.new"
	if [ "$(id -u)" -eq 0 ]; then
		chown --reference="$d/mis" "$libs/libcl_real.so.new" "$libs/libcl.so.new" 2>/dev/null || true
	fi
	mv -f "$libs/libcl_real.so.new" "$libs/libcl_real.so"
	mv -f "$libs/libcl.so.new" "$libs/libcl.so"
	msg "Installed libs/libcl.so (shim) and libs/libcl_real.so (Cryptlib)"
}

do_restore() {
	local d="$1" libs="$1/libs" bak
	[ -d "$libs" ] || die "$libs doesn't exist"
	bak="$libs/libcl.so.bak"
	[ -f "$bak" ] || bak="$(ls -1t "$libs"/libcl.so.bak.* 2>/dev/null | head -1 || true)"
	[ -n "$bak" ] && [ -f "$bak" ] || die "no backup (libcl.so.bak) found in $libs"
	step "Restoring $bak"
	cp -p "$bak" "$libs/libcl.so.restoring"
	mv -f "$libs/libcl.so.restoring" "$libs/libcl.so"
	rm -f -- "$libs/libcl_real.so"
	msg "Original library restored. Restart mis to use it."
}

choose_mystic_dir() {
	[ -n "$MYSTIC_DIR" ] && return 0
	local def; def="$(detect_mystic_dir || true)"
	[ -n "$def" ] || def="/mystic"
	pick_ui
	if [ "$UI" = "none" ]; then
		die "no terminal to ask on; pass the Mystic directory with -d DIR (built files are in $OUT_DIR)"
	fi
	MYSTIC_DIR="$(ui_input "Install location" \
		"Enter your Mystic BBS directory (the one containing mis, mystic and mystic.dat).\n\nLeave empty or cancel to skip installing; the built files stay in:\n$OUT_DIR" \
		"$def")" || MYSTIC_DIR=""
	[ -n "$MYSTIC_DIR" ] || { msg "Not installing. Built files are in $OUT_DIR"; exit 0; }
}

# ---- main -------------------------------------------------------------------
MYSTIC_VER=""
UNTESTED_NOTE=""
REAL_LIB=""

while [ $# -gt 0 ]; do
	case "$1" in
	-d|--mystic-dir) MYSTIC_DIR="${2:?missing value for $1}"; shift 2 ;;
	-o|--output-dir) OUT_DIR="${2:?missing value for $1}"; shift 2 ;;
	-b|--build-dir)  BUILD_DIR="${2:?missing value for $1}"; shift 2 ;;
	--source)        SOURCE_DIR="${2:?missing value for $1}"; shift 2 ;;
	--no-install)    DO_INSTALL=0; shift ;;
	--install-only)  INSTALL_ONLY=1; shift ;;
	--restore)       RESTORE=1; shift ;;
	--keep-build)    KEEP_BUILD=1; shift ;;
	-y|--yes)        ASSUME_YES=1; shift ;;
	--no-ui)         USE_UI=0; shift ;;
	-h|--help)       usage; exit 0 ;;
	*) usage >&2; die "unknown option: $1" ;;
	esac
done

HOST_ARCH="$(uname -m)"
[ -n "$OUT_DIR" ] || OUT_DIR="$SCRIPT_DIR/dist/$HOST_ARCH"
[ "$INSTALL_ONLY" -eq 0 ] || [ "$DO_INSTALL" -eq 1 ] || die "--install-only and --no-install contradict each other"

if [ "$RESTORE" -eq 1 ]; then
	[ -n "$MYSTIC_DIR" ] || die "--restore needs -d DIR"
	do_restore "$MYSTIC_DIR"
	exit 0
fi

if [ "$INSTALL_ONLY" -eq 0 ]; then
	preflight
	if [ -z "$BUILD_DIR" ]; then
		BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mystic-ssh-build.XXXXXX")"
		BUILD_DIR="$BUILD_TMP"
	else
		mkdir -p "$BUILD_DIR"
	fi
	SRC="$BUILD_DIR/cryptlib"
	STAGE="$BUILD_DIR/stage"
	mkdir -p "$STAGE"

	fetch_source "$SRC"
	patch_source "$SRC"
	build_cryptlib "$SRC"
	verify_real_lib
	build_shim "$STAGE"
	selftest "$STAGE" "$REAL_LIB" "$STAGE/libcl_shim.so" "$STAGE/shimtest"

	mkdir -p "$OUT_DIR"
	cp "$REAL_LIB" "$OUT_DIR/libcl_real.so"
	cp "$STAGE/libcl_shim.so" "$OUT_DIR/libcl.so"
	chmod 755 "$OUT_DIR/libcl_real.so" "$OUT_DIR/libcl.so"
	step "Build complete"
	msg "  $OUT_DIR/libcl.so       (shim, installs as libs/libcl.so)"
	msg "  $OUT_DIR/libcl_real.so  (Cryptlib, installs as libs/libcl_real.so)"
fi

if [ "$DO_INSTALL" -eq 0 ]; then
	msg ""
	msg "Not installing (--no-install).  To install later: $0 --install-only -d /path/to/mystic"
	exit 0
fi

choose_mystic_dir
[ -d "$MYSTIC_DIR" ] || die "$MYSTIC_DIR is not a directory"
MYSTIC_DIR="$(cd "$MYSTIC_DIR" && pwd)" || die "can't access $MYSTIC_DIR"
validate_mystic_dir "$MYSTIC_DIR"

[ -n "$UI" ] || pick_ui
ui_yesno "Install" "Install into:\n  $MYSTIC_DIR/libs\n\nMystic version: $MYSTIC_VER\nThe existing libs/libcl.so is backed up first.$UNTESTED_NOTE\n\nmis must be restarted afterwards." ||
	{ msg "Cancelled. Built files are in $OUT_DIR"; exit 0; }

do_install "$MYSTIC_DIR"

cat <<EOF

Done.  Next steps:
  1. Restart mis so it loads the new library, e.g.:
       systemctl restart mystic-bbs.service        (systemd)
       $MYSTIC_DIR/mis shutdown; $MYSTIC_DIR/mis daemon   (otherwise)
  2. Test:  ssh -vv -p <your ssh port> user@host   and look for aes128-ctr / aes256-ctr.
  3. In SyncTERM, enable "Allow early data" for the BBS entry (the server starts
     talking before the client finishes opening its channel).
  4. To undo:  $0 --restore -d $MYSTIC_DIR   (then restart mis)

If SSH stops working, mis logs "Cryptlib not detected" or a line from
mystic-libcl-shim (journalctl -t mystic-libcl-shim) explaining why.
EOF
