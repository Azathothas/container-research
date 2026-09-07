/* shim: an LD_PRELOAD interposer for the calls a chroot-emulating shim would
 * need. It records what it actually sees, which is the point: a Go binary
 * issues these as direct syscalls and never reaches this code.
 *
 * Build: gcc -O2 -shared -fPIC -o shim.so shim.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <sys/types.h>
#include <unistd.h>

static void note(const char *fn, const char *path)
{
	fprintf(stderr, "shim: intercepted %s(\"%s\")\n", fn, path);
}

int lchown(const char *path, uid_t u, gid_t g)
{
	static int (*real)(const char *, uid_t, gid_t);
	if (!real) real = dlsym(RTLD_NEXT, "lchown");
	note("lchown", path);
	return real(path, u, g);
}

int chown(const char *path, uid_t u, gid_t g)
{
	static int (*real)(const char *, uid_t, gid_t);
	if (!real) real = dlsym(RTLD_NEXT, "chown");
	note("chown", path);
	return real(path, u, g);
}

int open(const char *path, int flags, ...)
{
	static int (*real)(const char *, int, mode_t);
	if (!real) real = dlsym(RTLD_NEXT, "open");
	note("open", path);
	return real(path, flags, 0666);
}
