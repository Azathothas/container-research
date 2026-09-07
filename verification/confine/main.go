// confine models the paper's target runtime out of two independent mechanisms
// and execs a program under it, so that each observed denial can be attributed
// to the mechanism that actually produces it.
//
//	stage 0 (this process)  optionally acquires a supplementary group, then
//	                        re-execs itself in a user namespace whose ID maps
//	                        cover only 0->0 (CONFINE_USERNS=1).
//	stage 1 (the child)     optionally installs a seccomp filter
//	                        (CONFINE_SECCOMP=1) and execs argv[1:].
//
// Either stage can be turned off, which is the point: running the same probe
// under userns-only, seccomp-only and both isolates what each mechanism does.
//
//	CONFINE_USERNS=1              enter a user namespace, map only 0->0
//	CONFINE_SETGROUPS=allow       write "allow" to setgroups (default: deny)
//	CONFINE_EXTRA_GROUP=42        hold gid 42 before entering (it is unmapped
//	                              inside, so getgroups() reports overflowgid)
//	CONFINE_SECCOMP=1             install the seccomp filter
//	CONFINE_ALLOW_UNSHARE=1       drop the unshare(2) denial
//	CONFINE_ALLOW_MOUNT=1         drop the mount(2)/umount2(2) denial
//	CONFINE_ALLOW_PTRACE=1        drop the ptrace(2) denial
//	CONFINE_DENY_CLONE_NS=1       additionally deny clone(2) with any CLONE_NEW*
//	CONFINE_DENY_SETGROUPS=1      additionally deny setgroups(2) in the filter
//	CONFINE_DENY_CHOWN_NONZERO=1  additionally deny chown(2) to a nonzero id
//	CONFINE_DENY_SETUID_NONZERO=1 additionally deny setuid(2) to a nonzero id
//	CONFINE_DENY_MKNOD=1          additionally deny mknod(2)
package main

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"syscall"
	"unsafe"
)

type sockFilter struct {
	Code uint16
	Jt   uint8
	Jf   uint8
	K    uint32
}

type sockFprog struct {
	Len    uint16
	_      [6]byte
	Filter *sockFilter
}

const (
	bpfLdW  = 0x20 // BPF_LD|BPF_W|BPF_ABS
	bpfJeq  = 0x15 // BPF_JMP|BPF_JEQ|BPF_K
	bpfJset = 0x45 // BPF_JMP|BPF_JSET|BPF_K
	bpfRet  = 0x06 // BPF_RET|BPF_K

	offNR   = 0
	offArch = 4
	offArgs = 16 // seccomp_data.args[i] low word == 16 + 8*i

	auditArchX8664 = 0xC000003E
	retAllow       = 0x7fff0000
	retErrno       = 0x00050000
)

// x86-64 syscall numbers.
const (
	sysClone     = 56
	sysPtrace    = 101
	sysSetuid    = 105
	sysSetgroups = 116
	sysChown     = 92
	sysFchown    = 93
	sysLchown    = 94
	sysFchownat  = 260
	sysMknod     = 133
	sysMknodat   = 259
	sysMount     = 165
	sysUmount2   = 166
	sysPivotRoot = 155
	sysUnshare   = 272
	sysSetns     = 308
	sysSeccomp   = 317
)

// CLONE_NEWNS|NEWCGROUP|NEWUTS|NEWIPC|NEWUSER|NEWPID|NEWNET|NEWTIME.
const cloneNewMask = 0x00020000 | 0x02000000 | 0x04000000 | 0x08000000 |
	0x10000000 | 0x20000000 | 0x40000000 | 0x00000080

const (
	errPERM  = 1
	errINVAL = 22
)

func env(k string) bool { return os.Getenv(k) == "1" }

func errnoRet(e uint32) uint32 { return retErrno | (e & 0xffff) }

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: confine PROG [ARGS...]")
		os.Exit(2)
	}
	if env("CONFINE_USERNS") && os.Getenv("CONFINE_STAGE") != "1" {
		enterUserns()
		return
	}
	if env("CONFINE_SECCOMP") {
		installFilter()
	}
	if err := syscall.Exec(os.Args[1], os.Args[1:], os.Environ()); err != nil {
		fmt.Fprintln(os.Stderr, "confine: exec:", err)
		os.Exit(1)
	}
}

// enterUserns re-execs this binary inside a user namespace that maps only
// uid 0 and gid 0. Every other ID stays unmapped, which is what makes the
// kernel return EINVAL for setuid(1000) and chown(0,42) with no filter in
// play at all.
func enterUserns() {
	if g := os.Getenv("CONFINE_EXTRA_GROUP"); g != "" {
		gid, err := strconv.Atoi(g)
		if err != nil {
			fmt.Fprintln(os.Stderr, "confine: bad CONFINE_EXTRA_GROUP:", err)
			os.Exit(2)
		}
		groups := []uint32{0, uint32(gid)} // gid_t is 32-bit
		// AllThreadsSyscall so the credential holds on the thread that forks.
		if _, _, e := syscall.AllThreadsSyscall(syscall.SYS_SETGROUPS,
			uintptr(len(groups)), uintptr(unsafe.Pointer(&groups[0])), 0); e != 0 {
			fmt.Fprintln(os.Stderr, "confine: setgroups:", e)
		}
	}
	cmd := exec.Command("/proc/self/exe", os.Args[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	cmd.Env = append(os.Environ(), "CONFINE_STAGE=1")
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags:  syscall.CLONE_NEWUSER,
		UidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: 0, Size: 1}},
		GidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: 0, Size: 1}},
		// false makes Go write "deny" to /proc/<pid>/setgroups before the
		// gid map, which is what turns setgroups(2) into EPERM inside.
		GidMappingsEnableSetgroups: os.Getenv("CONFINE_SETGROUPS") == "allow",
	}
	err := cmd.Run()
	if ee, ok := err.(*exec.ExitError); ok {
		os.Exit(ee.ExitCode())
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "confine: userns:", err)
		os.Exit(1)
	}
}

func installFilter() {
	var f []sockFilter
	add := func(code uint16, jt, jf uint8, k uint32) {
		f = append(f, sockFilter{code, jt, jf, k})
	}

	add(bpfLdW, 0, 0, offArch)
	add(bpfJeq, 1, 0, auditArchX8664)
	add(bpfRet, 0, 0, errnoRet(errPERM))
	add(bpfLdW, 0, 0, offNR)

	// Unconditional denials. These are the filter's core: the operations the
	// target runtime refuses that a user namespace on its own would permit.
	type denial struct {
		nr   uint32
		e    uint32
		skip bool
	}
	denials := []denial{
		{sysUnshare, errPERM, env("CONFINE_ALLOW_UNSHARE")},
		{sysSetns, errPERM, env("CONFINE_ALLOW_UNSHARE")},
		{sysMount, errPERM, env("CONFINE_ALLOW_MOUNT")},
		{sysUmount2, errPERM, env("CONFINE_ALLOW_MOUNT")},
		{sysPivotRoot, errPERM, env("CONFINE_ALLOW_MOUNT")},
		{sysPtrace, errPERM, env("CONFINE_ALLOW_PTRACE")},
		{sysSetgroups, errPERM, !env("CONFINE_DENY_SETGROUPS")},
		{sysMknod, errPERM, !env("CONFINE_DENY_MKNOD")},
		{sysMknodat, errPERM, !env("CONFINE_DENY_MKNOD")},
	}
	for _, d := range denials {
		if d.skip {
			continue
		}
		add(bpfJeq, 0, 1, d.nr)
		add(bpfRet, 0, 0, errnoRet(d.e))
	}

	// clone(2) carrying any CLONE_NEW* flag. Off by default: the whole point
	// of the bubblewrap differential is that the target runtime permits it.
	if env("CONFINE_DENY_CLONE_NS") {
		add(bpfJeq, 0, 4, sysClone)
		add(bpfLdW, 0, 0, offArgs)
		add(bpfJset, 0, 1, cloneNewMask)
		add(bpfRet, 0, 0, errnoRet(errPERM))
		add(bpfLdW, 0, 0, offNR)
	}

	// Argument-conditional denials, used only to show that a filter can fake
	// what the user namespace produces natively.
	type argRule struct {
		nr  uint32
		idx int
		e   uint32
	}
	var argRules []argRule
	if env("CONFINE_DENY_SETUID_NONZERO") {
		argRules = append(argRules, argRule{sysSetuid, 0, errINVAL})
	}
	if env("CONFINE_DENY_CHOWN_NONZERO") {
		argRules = append(argRules,
			argRule{sysChown, 1, errINVAL}, argRule{sysChown, 2, errINVAL},
			argRule{sysLchown, 1, errINVAL}, argRule{sysLchown, 2, errINVAL},
			argRule{sysFchown, 1, errINVAL}, argRule{sysFchown, 2, errINVAL},
			argRule{sysFchownat, 2, errINVAL}, argRule{sysFchownat, 3, errINVAL})
	}
	for _, r := range argRules {
		add(bpfJeq, 0, 4, r.nr)
		add(bpfLdW, 0, 0, uint32(offArgs+8*r.idx))
		add(bpfJeq, 1, 0, 0)
		add(bpfRet, 0, 0, errnoRet(r.e))
		add(bpfLdW, 0, 0, offNR)
	}

	add(bpfRet, 0, 0, retAllow)

	if _, _, e := syscall.RawSyscall6(syscall.SYS_PRCTL,
		38 /* PR_SET_NO_NEW_PRIVS */, 1, 0, 0, 0, 0); e != 0 {
		fmt.Fprintln(os.Stderr, "confine: no_new_privs:", e)
		os.Exit(1)
	}
	prog := sockFprog{Len: uint16(len(f)), Filter: &f[0]}
	// seccomp(SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_TSYNC, &prog)
	if _, _, e := syscall.RawSyscall(sysSeccomp, 1, 1,
		uintptr(unsafe.Pointer(&prog))); e != 0 {
		fmt.Fprintln(os.Stderr, "confine: seccomp:", e)
		os.Exit(1)
	}
}
