/*
 * cl32.dll compatibility shim for Mystic BBS on Windows (32-bit).
 *
 * Windows port of the libcl.so shim from mystic-cryptlib-3.4.9.6 by
 * Christian Sacks (https://github.com/christiansacks/mystic-cryptlib-3.4.9.6),
 * GPL-2.0.  Shadowscope BBS, 11-2026.
 *
 * Mystic has the Cryptlib 3.4.5 numbers for attributes, session types and
 * keyset types compiled in.  Cryptlib 3.4.9 renumbered some of them.  This
 * DLL is what Mystic loads as cl32.dll: it exports the 26 functions Mystic
 * uses, translates the old numbers to the new ones (maps.h) and passes the
 * call on to the real Cryptlib 3.4.9.6, cl349.dll, in the same folder.
 *
 * Windows Cryptlib uses __stdcall, so unlike the Linux shim every function
 * here has its exact argument count (stdcall callee pops the arguments).
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "maps.h"

#define CL_UNUSED        -101
#define CL_INFO_MAJOR     103
#define CL_INFO_MINOR     104
#define CL_INFO_STEPPING  105
#define CL_ERROR_NOTAVAIL -20
#define CL_ERROR_FAILED   -15

static HMODULE real;
static int version_ok = 1;
static FILE *trace;
static char here[MAX_PATH];

static int xlate(const struct map *m, int v)
{
	for (; m->from; m++)
		if (m->from == v)
			return m->to;
	return v;
}

static void shim_log(const char *msg)
{
	char path[MAX_PATH + 32];
	FILE *f;
	snprintf(path, sizeof path, "%scl32shim.log", here);
	if ((f = fopen(path, "a")) != NULL) {
		SYSTEMTIME t;
		GetLocalTime(&t);
		fprintf(f, "%04d-%02d-%02d %02d:%02d:%02d  %s\n", t.wYear, t.wMonth, t.wDay,
		        t.wHour, t.wMinute, t.wSecond, msg);
		fclose(f);
	}
	OutputDebugStringA(msg);
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD why, LPVOID res)
{
	(void)res;
	if (why == DLL_PROCESS_ATTACH) {
		char path[MAX_PATH + 32], *slash;
		DisableThreadLibraryCalls(inst);
		GetModuleFileNameA(inst, here, MAX_PATH);
		slash = strrchr(here, '\\');
		if (slash) slash[1] = 0; else here[0] = 0;
		snprintf(path, sizeof path, "%scl349.dll", here);
		real = LoadLibraryA(path);
		if (getenv("CL_SHIM_TRACE"))
			trace = fopen(getenv("CL_SHIM_TRACE"), "a");
		if (!real) {
			char m[MAX_PATH + 96];
			snprintf(m, sizeof m, "cl32 shim: cannot load %s (error %lu) - SSH/SSL disabled",
			         path, GetLastError());
			shim_log(m);
		}
	}
	return TRUE;
}

static FARPROC get(const char *name)
{
	if (!real || !version_ok)
		return NULL;
	return GetProcAddress(real, name);
}

#define TR(fmt, ...) do { if (trace) { fprintf(trace, fmt "\n", __VA_ARGS__); fflush(trace); } } while (0)

typedef int (__stdcall *f0)(void);
typedef int (__stdcall *f1)(int);
typedef int (__stdcall *f2)(int, int);
typedef int (__stdcall *f3)(int, int, int);
typedef int (__stdcall *f4)(int, int, int, int);
typedef int (__stdcall *f5)(int, int, int, int, int);

/* Each export: name, arg count, which argument gets translated.  The
   translated argument is shown in the trace as old->new. */
#define EXP0(n) __declspec(dllexport) int __stdcall n(void) { \
	f0 p = (f0)get(#n); int r = p ? p() : CL_ERROR_NOTAVAIL; TR("%s() = %d", #n, r); return r; }
#define EXP1(n) __declspec(dllexport) int __stdcall n(int a) { \
	f1 p = (f1)get(#n); int r = p ? p(a) : CL_ERROR_NOTAVAIL; TR("%s(%d) = %d", #n, a, r); return r; }
#define EXP2(n) __declspec(dllexport) int __stdcall n(int a, int b) { \
	f2 p = (f2)get(#n); int r = p ? p(a, b) : CL_ERROR_NOTAVAIL; TR("%s(%d, %d) = %d", #n, a, b, r); return r; }
#define EXP3(n, XB, XC) __declspec(dllexport) int __stdcall n(int a, int b, int c) { \
	int ob = b, oc = c; f3 p = (f3)get(#n); int r; XB; XC; \
	r = p ? p(a, b, c) : CL_ERROR_NOTAVAIL; \
	TR("%s(%d, %d->%d, %d->%d) = %d", #n, a, ob, b, oc, c, r); return r; }
#define EXP4(n, XB) __declspec(dllexport) int __stdcall n(int a, int b, int c, int d) { \
	int ob = b; f4 p = (f4)get(#n); int r; XB; \
	r = p ? p(a, b, c, d) : CL_ERROR_NOTAVAIL; \
	TR("%s(%d, %d->%d, %d, %d) = %d", #n, a, ob, b, c, d, r); return r; }
#define EXP5(n, XC) __declspec(dllexport) int __stdcall n(int a, int b, int c, int d, int e) { \
	int oc = c; f5 p = (f5)get(#n); int r; XC; \
	r = p ? p(a, b, c, d, e) : CL_ERROR_NOTAVAIL; \
	TR("%s(%d, %d, %d->%d, %d, %d) = %d", #n, a, b, oc, c, d, e, r); return r; }

#define NOX   (void)0
#define ATTR  b = xlate(attr_map, b)
#define SESS  c = xlate(session_map, c)
#define KSET  c = xlate(keyset_map, c)

/* cryptInit: the first call Mystic makes.  Check that cl349.dll is the
   Cryptlib version maps.h was made for; if not, fail cleanly so Mystic says
   "Cryptlib not detected" and turns SSH off, rather than sending it the
   wrong numbers. */
__declspec(dllexport) int __stdcall cryptInit(void)
{
	f0 init;
	f3 getattr;
	f0 end;
	int r, maj = -1, mn = -1, st = -1;
	char m[256];

	if (!real)
		return CL_ERROR_NOTAVAIL;
	init = (f0)GetProcAddress(real, "cryptInit");
	if (!init)
		return CL_ERROR_NOTAVAIL;
	r = init();
	TR("cryptInit() = %d", r);
	if (r != 0 || !version_ok)
		return r;
	getattr = (f3)GetProcAddress(real, "cryptGetAttribute");
	if (getattr && getattr(CL_UNUSED, CL_INFO_MAJOR, (int)(INT_PTR)&maj) == 0 &&
	    getattr(CL_UNUSED, CL_INFO_MINOR, (int)(INT_PTR)&mn) == 0 &&
	    getattr(CL_UNUSED, CL_INFO_STEPPING, (int)(INT_PTR)&st) == 0 &&
	    maj == EXPECT_MAJOR && mn == EXPECT_MINOR && st == EXPECT_STEPPING)
		return r;
	if (getenv("CL_SHIM_ALLOW_VERSION_MISMATCH"))
		return r;
	snprintf(m, sizeof m, "cl32 shim: cl349.dll is Cryptlib %d.%d.%d but this shim is for "
	         "%d.%d.%d - SSH/SSL disabled", maj, mn, st, EXPECT_MAJOR, EXPECT_MINOR, EXPECT_STEPPING);
	shim_log(m);
	version_ok = 0;
	end = (f0)GetProcAddress(real, "cryptEnd");
	if (end)
		end();
	return CL_ERROR_NOTAVAIL;
}

EXP0(cryptEnd)
EXP2(cryptAddRandom)
EXP3(cryptCreateContext,      NOX, NOX)
EXP1(cryptDestroyContext)
EXP1(cryptGenerateKey)
EXP3(cryptEncrypt,            NOX, NOX)
EXP3(cryptDecrypt,            NOX, NOX)
EXP3(cryptCreateCert,         NOX, NOX)
EXP1(cryptDestroyCert)
EXP2(cryptSignCert)
EXP5(cryptKeysetOpen,         KSET)
EXP1(cryptKeysetClose)
EXP4(cryptGetPublicKey,       NOX)
EXP5(cryptGetPrivateKey,      NOX)
EXP2(cryptAddPublicKey)
EXP3(cryptAddPrivateKey,      NOX, NOX)
EXP3(cryptCreateSession,      NOX, SESS)
EXP1(cryptDestroySession)
EXP3(cryptSetAttribute,       ATTR, NOX)
EXP4(cryptSetAttributeString, ATTR)
EXP3(cryptGetAttribute,       ATTR, NOX)
EXP4(cryptGetAttributeString, ATTR)
EXP4(cryptPushData,           NOX)
EXP4(cryptPopData,            NOX)
EXP1(cryptFlushData)
