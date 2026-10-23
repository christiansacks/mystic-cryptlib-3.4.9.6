/*
 * libcl.so compatibility shim for Mystic BBS.
 *
 * Mystic hard-codes the Cryptlib 3.4.5 numeric values for attribute, session
 * type and keyset type constants.  Newer Cryptlib releases inserted entries
 * into those enums and shifted the values, so a newer libcl.so rejects or
 * misinterprets Mystic's calls.  This library exports the functions Mystic
 * dlsym()s, translates the old constants to the new ones, and forwards to the
 * real library, which is loaded from libcl_real.so next to this file.
 *
 * All the forwarded functions take only integer/pointer arguments (at most
 * five), so they can be passed through as six word-sized arguments.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <syslog.h>
#include "maps.h"

typedef long (*fn6)(long, long, long, long, long, long);

static void *real;
static FILE *trace;
static int version_ok = 1;

#define CL_UNUSED -101			/* CRYPT_UNUSED */
#define CL_INFO_MAJOR 103		/* CRYPT_OPTION_INFO_{MAJOR,MINOR}VERSION, STEPPING */
#define CL_INFO_MINOR 104
#define CL_INFO_STEPPING 105
#define CL_ERROR_NOTAVAIL -20

static int xlate(const struct map *m, int v)
{
	for (; m->from; m++)
		if (m->from == v)
			return m->to;
	return v;
}

__attribute__((constructor)) static void shim_init(void)
{
	Dl_info info;
	char path[PATH_MAX + 32], *slash;
	const char *override = getenv("CL_SHIM_REAL");

	if (override)
		real = dlopen(override, RTLD_NOW | RTLD_LOCAL);
	if (!real && dladdr((void *)shim_init, &info) && info.dli_fname) {
		strncpy(path, info.dli_fname, PATH_MAX);
		path[PATH_MAX] = 0;
		slash = strrchr(path, '/');
		strcpy(slash ? slash + 1 : path, "libcl_real.so");
		real = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	}
	if (!real)
		real = dlopen("libcl_real.so", RTLD_NOW | RTLD_LOCAL);
	if (getenv("CL_SHIM_TRACE"))
		trace = fopen(getenv("CL_SHIM_TRACE"), "a");
	if (!real)
		fprintf(stderr, "libcl shim: cannot load libcl_real.so: %s\n", dlerror());
}

#define FWD(name, xa, xb, xc)                                                  \
	long name(long a, long b, long c, long d, long e, long f)                  \
	{                                                                          \
		static fn6 fp;                                                         \
		if (!fp) {                                                             \
			if (!real || !version_ok)                                          \
				return -1;                                                     \
			fp = (fn6)dlsym(real, #name);                                      \
			if (!fp)                                                           \
				return -1;                                                     \
		}                                                                      \
		long ra = a, rb = b, rc = c;                                           \
		xa; xb; xc;                                                            \
		long r = fp(a, b, c, d, e, f);                                         \
		if (trace) {                                                           \
			fprintf(trace, "%s(%ld, %ld->%ld, %ld->%ld, %ld, %ld) = %d\n",    \
				#name, ra, rb, b, rc, c, d, e, (int)r);                        \
			fflush(trace);                                                     \
		}                                                                      \
		return r;                                                              \
	}

#define NOX (void)0
#define ATTR  b = xlate(attr_map, (int)b)
#define SESS  c = xlate(session_map, (int)c)
#define KSET  c = xlate(keyset_map, (int)c)

/*
 * cryptInit is the first call Mystic makes, so verify here that the real
 * library is the version the translation tables were generated for.  On a
 * mismatch fail cleanly (Mystic reports "Cryptlib not detected" and disables
 * SSL/SSH) rather than send it wrongly-numbered constants.
 */
long cryptInit(long a, long b, long c, long d, long e, long f)
{
	typedef int (*getattr_fn)(long, long, int *);
	fn6 init, end;
	getattr_fn getattr;
	int maj = -1, min = -1, step = -1;
	long r;

	if (!real)
		return -1;
	init = (fn6)dlsym(real, "cryptInit");
	if (!init)
		return -1;
	r = init(a, b, c, d, e, f);
	if ((int)r != 0 || !version_ok)
		return r;

	getattr = (getattr_fn)dlsym(real, "cryptGetAttribute");
	if (getattr && getattr(CL_UNUSED, CL_INFO_MAJOR, &maj) == 0 &&
	    getattr(CL_UNUSED, CL_INFO_MINOR, &min) == 0 &&
	    getattr(CL_UNUSED, CL_INFO_STEPPING, &step) == 0 &&
	    maj == EXPECT_MAJOR && min == EXPECT_MINOR && step == EXPECT_STEPPING)
		return r;

	if (getenv("CL_SHIM_ALLOW_VERSION_MISMATCH"))
		return r;

	openlog("mystic-libcl-shim", LOG_PID, LOG_DAEMON);
	syslog(LOG_ERR, "libcl_real.so is Cryptlib %d.%d.%d but this shim was generated for "
	       "%d.%d.%d; refusing to load (regenerate maps.h, see UPGRADING.md, or set "
	       "CL_SHIM_ALLOW_VERSION_MISMATCH=1 to override)",
	       maj, min, step, EXPECT_MAJOR, EXPECT_MINOR, EXPECT_STEPPING);
	closelog();
	fprintf(stderr, "libcl shim: real library is Cryptlib %d.%d.%d, expected %d.%d.%d; "
	        "SSH/SSL disabled\n", maj, min, step, EXPECT_MAJOR, EXPECT_MINOR, EXPECT_STEPPING);
	version_ok = 0;
	end = (fn6)dlsym(real, "cryptEnd");
	if (end)
		end(0, 0, 0, 0, 0, 0);
	return CL_ERROR_NOTAVAIL;
}
FWD(cryptEnd,                 NOX, NOX, NOX)
FWD(cryptAddRandom,           NOX, NOX, NOX)
FWD(cryptCreateContext,       NOX, NOX, NOX)
FWD(cryptDestroyContext,      NOX, NOX, NOX)
FWD(cryptGenerateKey,         NOX, NOX, NOX)
FWD(cryptEncrypt,             NOX, NOX, NOX)
FWD(cryptDecrypt,             NOX, NOX, NOX)
FWD(cryptCreateCert,          NOX, NOX, NOX)
FWD(cryptDestroyCert,         NOX, NOX, NOX)
FWD(cryptSignCert,            NOX, NOX, NOX)
FWD(cryptKeysetOpen,          KSET, NOX, NOX)
FWD(cryptKeysetClose,         NOX, NOX, NOX)
FWD(cryptGetPublicKey,        NOX, NOX, NOX)
FWD(cryptGetPrivateKey,       NOX, NOX, NOX)
FWD(cryptAddPublicKey,        NOX, NOX, NOX)
FWD(cryptAddPrivateKey,       NOX, NOX, NOX)
FWD(cryptCreateSession,       SESS, NOX, NOX)
FWD(cryptDestroySession,      NOX, NOX, NOX)
FWD(cryptSetAttribute,        ATTR, NOX, NOX)
FWD(cryptSetAttributeString,  ATTR, NOX, NOX)
FWD(cryptGetAttribute,        ATTR, NOX, NOX)
FWD(cryptGetAttributeString,  ATTR, NOX, NOX)
FWD(cryptPushData,            NOX, NOX, NOX)
FWD(cryptPopData,             NOX, NOX, NOX)
FWD(cryptFlushData,           NOX, NOX, NOX)
