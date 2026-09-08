// confine models the paper's target runtime out of three independent
// mechanisms and execs a program under it, so that each observed denial can be
// attributed to the mechanism that actually produces it.
//
//	stage 0 (this process)  optionally acquires a supplementary group, then
//	                        re-execs itself in a user namespace with a partial
//	                        ID map (CONFINE_USERNS=1).
//	stage 1 (the child)     optionally applies a Landlock write allowlist
//	                        (CONFINE_LANDLOCK), installs a seccomp filter
//	                        (CONFINE_SECCOMP=1), and execs argv[1:].
//
// Any stage can be turned off, which is the point: running the same probe
// under one mechanism at a time isolates what each does.
//
//	N — user namespace
//	CONFINE_USERNS=1              enter a user namespace with a partial ID map
//	CONFINE_MAP_HOSTID=1000       map 0 -> this host id (default 0; the target
//	                              runtime maps 0 -> 1000, verification/real/identity.txt)
//	CONFINE_MOUNTNS=1             also give the child a mount namespace owned by
//	                              that user namespace, which is what makes
//	                              may_mount() pass (the target has one)
//	CONFINE_SETGROUPS=allow       write "allow" to setgroups (default: deny)
//	CONFINE_EXTRA_GROUP=42        hold gid 42 before entering (it is unmapped
//	                              inside, so getgroups() reports overflowgid)
//
//	F — seccomp filter
//	CONFINE_SECCOMP=1             install the seccomp filter
//	CONFINE_ALLOW_UNSHARE=1       drop the unshare(2)/setns(2) denial
//	CONFINE_ALLOW_MOUNT=1         drop the mount(2)/umount2(2)/pivot_root(2) denial
//	CONFINE_ALLOW_PTRACE=1        drop the ptrace(2) denial
//	CONFINE_DENY_PROCESS_VM=1     also deny process_vm_readv/writev, as the
//	                              target's filter does (paper §3.7a)
//	CONFINE_DENY_CLONE_NS=1       additionally deny clone(2) with any CLONE_NEW*
//	CONFINE_DENY_SETGROUPS=1      additionally deny setgroups(2) in the filter
//	CONFINE_DENY_CHOWN_NONZERO=1  additionally deny chown(2) to a nonzero id
//	CONFINE_DENY_SETUID_NONZERO=1 additionally deny setuid(2) to a nonzero id
//	CONFINE_DENY_MKNOD=1          additionally deny mknod(2)
//
//	M — path-scoped LSM
//	CONFINE_LANDLOCK=/tmp:/state  restrict writes to these subtrees (reads stay
//	                              unrestricted). Also denies every mount-topology
//	                              operation, including move_mount(2), because
//	                              landlock's sb_mount/move_mount hooks refuse
//	                              whenever any filesystem right is handled.
//
//	CONFINE_VERBOSE=1             report what was applied, on stderr
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

	sysProcessVMReadv  = 310
	sysProcessVMWritev = 311
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
	// M before F: a Landlock ruleset needs open(2) on each allowlisted path,
	// and the filter has no reason to permit it separately.
	if p := os.Getenv("CONFINE_LANDLOCK"); p != "" {
		if err := applyLandlock(p); err != nil {
			fmt.Fprintln(os.Stderr, "confine:", err)
			os.Exit(1)
		}
	}
	if env("CONFINE_SECCOMP") {
		installFilter()
	}
	if err := syscall.Exec(os.Args[1], os.Args[1:], os.Environ()); err != nil {
		fmt.Fprintln(os.Stderr, "confine: exec:", err)
		os.Exit(1)
	}
}

// enterUserns re-execs this binary inside a user namespace that maps a single
// ID: container 0 -> CONFINE_MAP_HOSTID (0 by default, 1000 on the target).
// Every other ID stays unmapped, which is what makes the kernel return EINVAL
// for setuid(1000) and chown(0,42) with no filter in play at all. Which host
// ID sits behind the map changes nothing about that: what matters is that the
// map has one entry.
func enterUserns() {
	hostID := 0
	if v := os.Getenv("CONFINE_MAP_HOSTID"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			fmt.Fprintln(os.Stderr, "confine: bad CONFINE_MAP_HOSTID:", err)
			os.Exit(2)
		}
		hostID = n
	}
	if g := os.Getenv("CONFINE_EXTRA_GROUP"); g != "" {
		gid, err := strconv.Atoi(g)
		if err != nil {
			fmt.Fprintln(os.Stderr, "confine: bad CONFINE_EXTRA_GROUP:", err)
			os.Exit(2)
		}
		// The first entry is the one the map covers, so it shows up as gid 0
		// inside; the second is unmapped and shows up as overflowgid.
		groups := []uint32{uint32(hostID), uint32(gid)} // gid_t is 32-bit
		// AllThreadsSyscall so the credential holds on the thread that forks.
		if _, _, e := syscall.AllThreadsSyscall(syscall.SYS_SETGROUPS,
			uintptr(len(groups)), uintptr(unsafe.Pointer(&groups[0])), 0); e != 0 {
			fmt.Fprintln(os.Stderr, "confine: setgroups:", e)
		}
	}
	// A map of 0 -> hostID only makes the child uid 0 if the child's real
	// credential *is* hostID: the map translates that id and nothing else, so
	// a child still running as host root would land on overflowuid with an
	// empty capability set. Drop to hostID here, before the clone, which is
	// also what the target's sandbox init does (its map is 0 -> 1000 and it
	// runs as 1000). Writing a single-entry map for one's own id needs no
	// privilege, so the drop costs nothing.
	if hostID != 0 {
		if _, _, e := syscall.AllThreadsSyscall(syscall.SYS_SETRESGID,
			uintptr(hostID), uintptr(hostID), uintptr(hostID)); e != 0 {
			fmt.Fprintln(os.Stderr, "confine: setresgid:", e)
			os.Exit(1)
		}
		if _, _, e := syscall.AllThreadsSyscall(syscall.SYS_SETRESUID,
			uintptr(hostID), uintptr(hostID), uintptr(hostID)); e != 0 {
			fmt.Fprintln(os.Stderr, "confine: setresuid:", e)
			os.Exit(1)
		}
		// Changing euid clears the dumpable flag, which makes /proc/self owned
		// by root and mode 0555 — so the re-exec below fails EACCES on
		// /proc/self/exe, with nothing in the message to say why. Restore it.
		if _, _, e := syscall.AllThreadsSyscall(syscall.SYS_PRCTL,
			4 /* PR_SET_DUMPABLE */, 1, 0); e != 0 {
			fmt.Fprintln(os.Stderr, "confine: set_dumpable:", e)
			os.Exit(1)
		}
	}
	cmd := exec.Command("/proc/self/exe", os.Args[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	cmd.Env = append(os.Environ(), "CONFINE_STAGE=1")
	// CONFINE_MOUNTNS gives the child a mount namespace *owned by* the new
	// user namespace. It matters more than it looks: may_mount() asks for
	// CAP_SYS_ADMIN in current->nsproxy->mnt_ns->user_ns (fs/namespace.c,
	// v6.18), so without it fsopen/fsmount/open_tree fail EPERM even though
	// the process is root in its own user namespace. The target passes that
	// check (verification/real/extkernel-newapi.txt), so a faithful model of
	// the target needs this flag; the paper's original §3.2 model, which did
	// not set it, is a strictly weaker environment on that one axis.
	cloneFlags := uintptr(syscall.CLONE_NEWUSER)
	if env("CONFINE_MOUNTNS") {
		cloneFlags |= syscall.CLONE_NEWNS
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags:  cloneFlags,
		UidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: hostID, Size: 1}},
		GidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: hostID, Size: 1}},
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
		// The target's filter denies these two as well (paper §3.7a): they
		// return EPERM for a pid that does not exist, where the kernel would
		// answer ESRCH. Off by default so older sections keep their meaning.
		{sysProcessVMReadv, errPERM, !env("CONFINE_DENY_PROCESS_VM")},
		{sysProcessVMWritev, errPERM, !env("CONFINE_DENY_PROCESS_VM")},
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
