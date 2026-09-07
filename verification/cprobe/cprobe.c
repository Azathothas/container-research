/* cprobe: single-threaded companion to probe.
 *
 * A Go program cannot probe unshare(CLONE_NEWUSER) or unshare(CLONE_NEWTIME):
 * the Go runtime is multithreaded, and the kernel refuses both for a process
 * that shares its address space with other threads, returning EINVAL whatever
 * the policy is. Every verdict on those flags has to come from a
 * single-threaded prober such as this one, or from a clone(2) instead.
 *
 * Build: gcc -O2 -static -o cprobe cprobe.c
 */
#define _GNU_SOURCE
#include <errno.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/sysmacros.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static void report(const char *name, long rc)
{
	if (rc >= 0)
		printf("%-34s OK\n", name);
	else
		printf("%-34s FAIL errno=%d %s\n", name, errno, strerror(errno));
	fflush(stdout);
}

/* Run one probe in a forked child so a success cannot leak into the next. */
#define ISOLATED(name, expr)                     \
	do {                                     \
		pid_t p = fork();                \
		if (p == 0) {                    \
			report(name, (long)(expr)); \
			_exit(0);                \
		}                                \
		waitpid(p, NULL, 0);             \
	} while (0)

#include <sys/wait.h>

int main(void)
{
	ISOLATED("unshare(CLONE_NEWUSER) [1 thread]", unshare(CLONE_NEWUSER));
	ISOLATED("unshare(CLONE_NEWNS) [1 thread]", unshare(CLONE_NEWNS));
	ISOLATED("unshare(CLONE_NEWPID) [1 thread]", unshare(CLONE_NEWPID));
	ISOLATED("unshare(CLONE_NEWUTS) [1 thread]", unshare(CLONE_NEWUTS));
	unlink("/tmp/cnodprobe");
	unlink("/tmp/cwprobe");
	ISOLATED("mknod(chr 1:3) [CAP_MKNOD]", mknod("/tmp/cnodprobe", S_IFCHR | 0600, makedev(1, 3)));
	ISOLATED("mknod(chr 0:0) [whiteout]", mknod("/tmp/cwprobe", S_IFCHR | 0600, makedev(0, 0)));
	ISOLATED("setuid(1000)", syscall(SYS_setuid, 1000));
	ISOLATED("setgroups(0,NULL)", syscall(SYS_setgroups, 0, NULL));
	ISOLATED("chroot(/tmp) [CAP_SYS_CHROOT]", chroot("/tmp"));
	return 0;
}
