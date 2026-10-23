/* Post-build self-test: load the shim, init Cryptlib through it, make a context. */
#include <stdio.h>
#include <dlfcn.h>

int main(int argc, char **argv)
{
	void *h;
	int (*init)(void), (*end)(void), (*mk)(int *, int, int), (*destroy)(int);
	int r, ctx = 0;

	if (argc < 2 || !(h = dlopen(argv[1], RTLD_NOW))) {
		fprintf(stderr, "dlopen failed: %s\n", argc < 2 ? "no path" : dlerror());
		return 2;
	}
	init = dlsym(h, "cryptInit");
	end = dlsym(h, "cryptEnd");
	mk = dlsym(h, "cryptCreateContext");
	destroy = dlsym(h, "cryptDestroyContext");
	if (!init || !end || !mk || !destroy)
		return 3;
	if ((r = init()) != 0) {
		fprintf(stderr, "cryptInit returned %d\n", r);
		return 4;
	}
	/* CRYPT_UNUSED = -101, CRYPT_ALGO_AES = 2 */
	if ((r = mk(&ctx, -101, 2)) != 0) {
		fprintf(stderr, "cryptCreateContext(AES) returned %d\n", r);
		return 5;
	}
	destroy(ctx);
	end();
	return 0;
}
