/* cltest.exe - checks cl32.dll + cl349.dll in this folder outside Mystic.
   Shadowscope BBS 11-2026.  Writes cltest.log and shows the result. */
#define NOCRYPT
#include <windows.h>
#include <stdio.h>
#define CTXLABEL 1016
typedef int (__stdcall *F0)(void); typedef int (__stdcall *F3)(int,int,int); typedef int (__stdcall *F1)(int); typedef int (__stdcall *F4)(int,int,int,int);
int main(void) {
  FILE *f = fopen("cltest.log", "w"); char m[512]; int r, ctx = 0, v[3] = {-1,-1,-1};
  #define OUT(...) do { snprintf(m, sizeof m, __VA_ARGS__); printf("%s\n", m); if (f) { fprintf(f, "%s\n", m); fflush(f); } } while (0)
  HMODULE real = LoadLibraryA(".\\cl349.dll");
  OUT("cl349.dll direct load: %s (error %lu)", real ? "OK" : "FAILED", real ? 0UL : GetLastError());
  if (real) FreeLibrary(real);
  HMODULE h = LoadLibraryA(".\\cl32.dll");
  OUT("cl32.dll (shim) load: %s (error %lu)", h ? "OK" : "FAILED", h ? 0UL : GetLastError());
  if (!h) goto done;
  F0 init = (F0)GetProcAddress(h, "cryptInit");
  r = init ? init() : -999; OUT("cryptInit = %d", r);
  if (r) goto done;
  F3 ga = (F3)GetProcAddress(h, "cryptGetAttribute");
  ga(-101, 103, (int)&v[0]); ga(-101, 104, (int)&v[1]); ga(-101, 105, (int)&v[2]);
  OUT("Cryptlib version %d.%d.%d", v[0], v[1], v[2]);
  r = ((F3)GetProcAddress(h, "cryptCreateContext"))((int)&ctx, -101, 2); OUT("create AES context = %d", r);
  if (!r) ((F1)GetProcAddress(h, "cryptDestroyContext"))(ctx);
  r = ((F3)GetProcAddress(h, "cryptCreateContext"))((int)&ctx, -101, 101); OUT("create RSA context = %d", r);
  if (!r) { ((F4)GetProcAddress(h, "cryptSetAttributeString"))(ctx, CTXLABEL, (int)"test", 4);
            r = ((F1)GetProcAddress(h, "cryptGenerateKey"))(ctx); OUT("generate RSA key = %d", r); }
  ((F0)GetProcAddress(h, "cryptEnd"))();
done:
  OUT("(0 = OK)  Press Enter to close.");
  if (f) fclose(f);
  getchar(); return 0;
}
