// probe runs the runtime census one operation at a time.
//
// Every operation that would mutate the caller if it succeeded (unshare,
// chroot, setuid, setgroups, ...) runs in a freshly forked child, so a probe
// that passes cannot silently change the environment the next probe sees.
//
//	probe id                 identity, capability and seccomp status
//	probe census             run every check, one child each
//	probe check <name>       run exactly one check in this process
//	probe attribute          bogus-argument probes: filter vs kernel-internal
//	probe spawn              Go os/exec credential matrix
package main

import (
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"syscall"
	"unsafe"
)

func cstr(s string) uintptr {
	b, _ := syscall.BytePtrFromString(s)
	return uintptr(unsafe.Pointer(b))
}

func raw(trap uintptr, a ...uintptr) error {
	var args [6]uintptr
	copy(args[:], a)
	_, _, e := syscall.Syscall6(trap, args[0], args[1], args[2], args[3], args[4], args[5])
	if e != 0 {
		return e
	}
	return nil
}

// spawnCloned forks a child with the given clone flags and reports whether
// the clone itself was accepted.
func spawnCloned(flags uintptr, argv ...string) error {
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Cloneflags: flags}
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	return cmd.Run()
}

var checks = map[string]func() error{
	"unshare(CLONE_NEWNS)":   func() error { return syscall.Unshare(syscall.CLONE_NEWNS) },
	"unshare(CLONE_NEWUSER)": func() error { return syscall.Unshare(syscall.CLONE_NEWUSER) },
	"unshare(CLONE_NEWPID)":  func() error { return syscall.Unshare(syscall.CLONE_NEWPID) },
	"clone(CLONE_NEWNS)":     func() error { return spawnCloned(syscall.CLONE_NEWNS, "/bin/true") },
	"clone(CLONE_NEWUTS|NEWNS)": func() error {
		return spawnCloned(syscall.CLONE_NEWUTS|syscall.CLONE_NEWNS, "/bin/true")
	},
	"clone(CLONE_NEWUSER)": func() error { return spawnCloned(syscall.CLONE_NEWUSER, "/bin/true") },
	"mount(tmpfs,/mnt)": func() error {
		return syscall.Mount("none", "/mnt", "tmpfs", 0, "")
	},
	"mount(MS_SLAVE,/) in clone(NEWNS)": func() error {
		return spawnCloned(syscall.CLONE_NEWNS, "/proc/self/exe", "check", "mount(MS_SLAVE,/)")
	},
	"mount(MS_SLAVE,/)": func() error {
		return syscall.Mount("", "/", "", syscall.MS_SLAVE|syscall.MS_REC, "")
	},
	"pivot_root(/tmp,/tmp)":  func() error { return syscall.PivotRoot("/tmp", "/tmp") },
	"ptrace(PTRACE_TRACEME)": func() error { return raw(syscall.SYS_PTRACE, 0, 0, 0, 0) },
	// dev must not be 0: mknod(S_IFCHR, 0) is WHITEOUT_DEV, which the kernel
	// creates without CAP_MKNOD. Probing with 0 tests nothing. 0x103 is 1:3.
	"mknod(chr 1:3 /tmp/nodprobe)": func() error {
		os.Remove("/tmp/nodprobe")
		return syscall.Mknod("/tmp/nodprobe", syscall.S_IFCHR|0600, 0x103)
	},
	"mknod(chr 0:0 = whiteout)": func() error {
		os.Remove("/tmp/wprobe")
		return syscall.Mknod("/tmp/wprobe", syscall.S_IFCHR|0600, 0)
	},
	"setuid(1000)":      func() error { return raw(syscall.SYS_SETUID, 1000) },
	"setuid(0)":         func() error { return raw(syscall.SYS_SETUID, 0) },
	"setgid(0)":         func() error { return raw(syscall.SYS_SETGID, 0) },
	"setgroups(0,NULL)": func() error { return raw(syscall.SYS_SETGROUPS, 0, 0) },
	"chown(f,0,0)":      func() error { return chownProbe(0, 0) },
	"chown(f,0,42)":     func() error { return chownProbe(0, 42) },
	"lchown(f,0,42)": func() error {
		touch(chownTarget)
		return syscall.Lchown(chownTarget, 0, 42)
	},
	"chown(f,1000,0)":   func() error { return chownProbe(1000, 0) },
	"chroot(/tmp)":      func() error { return raw(syscall.SYS_CHROOT, cstr("/tmp")) },
	"memfd_create":      func() error { return memfdProbe(false) },
	"memfd_create+exec": func() error { return memfdProbe(true) },
	"setsid":            func() error { return raw(syscall.SYS_SETSID) },
	"prctl(PR_SET_PDEATHSIG)": func() error {
		return raw(syscall.SYS_PRCTL, 1 /* PR_SET_PDEATHSIG */, uintptr(syscall.SIGTERM))
	},
	"exec(/tmp/execprobe)": func() error { return execProbe() },
	"getrandom":            func() error { return raw(318, cstr(""), 0, 0) },
	"write(/etc/probe)": func() error {
		f, err := os.Create("/etc/probe")
		if err != nil {
			return err
		}
		f.Close()
		os.Remove("/etc/probe")
		return nil
	},
	// The "root squash" observation: a directory owned by an ID that is not
	// mapped in this user namespace is unwritable even with CAP_DAC_OVERRIDE.
	//
	// The fixture has to be built by something that can chown, which the
	// confined process cannot. When it is absent the probe must say so: an
	// ENOENT here would otherwise read as a denial and be attributed to a
	// mechanism, which is the same class of bug as a verdict taken from an
	// exit code.
	"write into uid-1000-owned dir": func() error {
		if fi, err := os.Stat(squashDir); err != nil || !fi.IsDir() {
			return errSkip("fixture " + squashDir + " absent; create it as " +
				"uid 1000 outside the confinement")
		}
		f, err := os.Create(squashDir + "/x")
		if err != nil {
			return err
		}
		f.Close()
		os.Remove(squashDir + "/x")
		return nil
	},
}

const (
	// Distinct from the cprobe binary the harness builds: an earlier revision
	// used /tmp/cprobe for both, and the census silently truncated the C probe
	// to an empty 0644 file, so the next run reported "Permission denied"
	// instead of a census (verification/real/cprobe.txt is that artefact).
	chownTarget = "/tmp/chown-probe-target"
	squashDir   = "/tmp/squash-probe"
)

// errSkip marks a check whose precondition is missing, so that "not measured"
// never prints as "denied".
type errSkip string

func (e errSkip) Error() string { return string(e) }

// order fixes the census output so runs are diffable.
var order = []string{
	"unshare(CLONE_NEWNS)", "unshare(CLONE_NEWUSER)", "unshare(CLONE_NEWPID)",
	"clone(CLONE_NEWNS)", "clone(CLONE_NEWUTS|NEWNS)", "clone(CLONE_NEWUSER)",
	"mount(tmpfs,/mnt)", "mount(MS_SLAVE,/)", "mount(MS_SLAVE,/) in clone(NEWNS)",
	"pivot_root(/tmp,/tmp)", "ptrace(PTRACE_TRACEME)",
	"mknod(chr 1:3 /tmp/nodprobe)", "mknod(chr 0:0 = whiteout)",
	"setuid(1000)", "setuid(0)", "setgid(0)", "setgroups(0,NULL)",
	"chown(f,0,0)", "chown(f,0,42)", "lchown(f,0,42)", "chown(f,1000,0)",
	"chroot(/tmp)", "memfd_create", "memfd_create+exec", "setsid",
	"prctl(PR_SET_PDEATHSIG)", "exec(/tmp/execprobe)", "getrandom",
	"write(/etc/probe)", "write into uid-1000-owned dir",
}

// touch replaces the file, so a chown probe never inherits an owner set by a
// previous probe.
func touch(p string) {
	os.Remove(p)
	f, err := os.Create(p)
	if err == nil {
		f.Close()
	}
}

func chownProbe(uid, gid int) error {
	touch(chownTarget)
	return syscall.Chown(chownTarget, uid, gid)
}

func memfdProbe(execIt bool) error {
	// No MFD_CLOEXEC: the fd has to survive the fork+exec for /proc/self/fd/N
	// to name it in the child.
	r, _, e := syscall.Syscall(319 /* memfd_create */, cstr("probe"), 0, 0)
	if e != 0 {
		return e
	}
	fd := int(r)
	defer syscall.Close(fd)
	if !execIt {
		return nil
	}
	script := []byte("#!/bin/sh\nexit 0\n")
	if _, err := syscall.Write(fd, script); err != nil {
		return err
	}
	return exec.Command(fmt.Sprintf("/proc/self/fd/%d", fd)).Run()
}

func execProbe() error {
	const p = "/tmp/execprobe"
	if err := os.WriteFile(p, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		return err
	}
	return exec.Command(p).Run()
}

func format(name string, err error) string {
	if err == nil {
		return fmt.Sprintf("%-34s OK", name)
	}
	if s, ok := err.(errSkip); ok {
		return fmt.Sprintf("%-34s SKIP %s", name, string(s))
	}
	if e, ok := err.(syscall.Errno); ok {
		return fmt.Sprintf("%-34s FAIL errno=%d %s", name, int(e), errName(int(e)))
	}
	if ee, ok := err.(*os.PathError); ok {
		if e, ok := ee.Err.(syscall.Errno); ok {
			return fmt.Sprintf("%-34s FAIL errno=%d %s", name, int(e), errName(int(e)))
		}
	}
	msg := err.Error()
	if i := strings.LastIndex(msg, ": "); i >= 0 && strings.Contains(msg, "fork/exec") {
		return fmt.Sprintf("%-34s FAIL %s", name, msg)
	}
	return fmt.Sprintf("%-34s FAIL %v", name, err)
}

func errName(e int) string {
	switch e {
	case 1:
		return "EPERM"
	case 2:
		return "ENOENT"
	case 3:
		return "ESRCH"
	case 9:
		return "EBADF"
	case 13:
		return "EACCES"
	case 19:
		return "ENODEV"
	case 20:
		return "ENOTDIR"
	case 22:
		return "EINVAL"
	case 28:
		return "ENOSPC"
	case 38:
		return "ENOSYS"
	default:
		return fmt.Sprintf("(%d)", e)
	}
}

func spawn(label string, attr *syscall.SysProcAttr) {
	cmd := exec.Command("/bin/true")
	cmd.SysProcAttr = attr
	fmt.Println(format(label, cmd.Run()))
}

func main() {
	mode := "census"
	if len(os.Args) > 1 {
		mode = os.Args[1]
	}
	switch mode {
	case "id":
		printID()
	case "check":
		name := os.Args[2]
		fn, ok := checks[name]
		if !ok {
			fn, ok = attrChecks[name]
		}
		if !ok {
			fmt.Fprintln(os.Stderr, "no such check:", name)
			os.Exit(2)
		}
		err := fn()
		fmt.Println(format(name, err))
		// Exit non-zero on failure so a parent that re-execs this binary
		// (eg. the "in clone(NEWNS)" mount row) can report the verdict from
		// the exit code instead of silently succeeding. 2 separates "could
		// not run" from "ran and was denied".
		if _, skipped := err.(errSkip); skipped {
			os.Exit(2)
		}
		if err != nil {
			os.Exit(1)
		}
	case "census":
		// One child per check: a check that succeeds cannot leak its effect
		// into the next one.
		for _, name := range order {
			out, _ := exec.Command("/proc/self/exe", "check", name).CombinedOutput()
			os.Stdout.Write(out)
		}
	case "attribute":
		for _, name := range attrOrder {
			out, _ := exec.Command("/proc/self/exe", "check", name).CombinedOutput()
			os.Stdout.Write(out)
		}
	case "spawn":
		spawn("no SysProcAttr", nil)
		spawn("SysProcAttr{} (no Credential)", &syscall.SysProcAttr{})
		spawn("Credential{0,0}", &syscall.SysProcAttr{
			Credential: &syscall.Credential{Uid: 0, Gid: 0}})
		spawn("Credential{0,0}+GidMapEnableSetgroups", &syscall.SysProcAttr{
			Credential:                 &syscall.Credential{Uid: 0, Gid: 0},
			GidMappingsEnableSetgroups: true,
			Pdeathsig:                  syscall.SIGTERM})
		spawn("Credential{0,0,NoSetGroups:true}", &syscall.SysProcAttr{
			Credential: &syscall.Credential{Uid: 0, Gid: 0, NoSetGroups: true}})
		spawn("Credential{0,0,NoSetGroups}+Pdeath", &syscall.SysProcAttr{
			Credential: &syscall.Credential{Uid: 0, Gid: 0, NoSetGroups: true},
			Pdeathsig:  syscall.SIGTERM})
		// The other documented exception: a gid map with setgroups disabled
		// and an empty group list also suppresses the call.
		spawn("GidMappings+!EnableSetgroups", &syscall.SysProcAttr{
			Cloneflags:  syscall.CLONE_NEWUSER,
			Credential:  &syscall.Credential{Uid: 0, Gid: 0},
			UidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: 0, Size: 1}},
			GidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: 0, Size: 1}}})
		spawn("Cloneflags=CLONE_NEWNS", &syscall.SysProcAttr{
			Cloneflags: syscall.CLONE_NEWNS})
		spawn("Cloneflags=NEWUTS|NEWNS", &syscall.SysProcAttr{
			Cloneflags: syscall.CLONE_NEWUTS | syscall.CLONE_NEWNS})
		spawn("Cloneflags=NEWNS + Credential{0,0}", &syscall.SysProcAttr{
			Cloneflags: syscall.CLONE_NEWNS,
			Credential: &syscall.Credential{Uid: 0, Gid: 0}})
	default:
		fmt.Fprintln(os.Stderr, "usage: probe id|census|check <name>|spawn")
		os.Exit(2)
	}
}

func printID() {
	uid, gid := syscall.Getuid(), syscall.Getgid()
	groups, _ := syscall.Getgroups()
	// getgroups(2) makes no ordering guarantee; sorting keeps runs diffable,
	// which is the same reason the census has a fixed order.
	sort.Ints(groups)
	fmt.Printf("uid=%d gid=%d groups=%v\n", uid, gid, groups)
	status, _ := os.ReadFile("/proc/self/status")
	for _, line := range strings.Split(string(status), "\n") {
		switch {
		case strings.HasPrefix(line, "CapPrm"), strings.HasPrefix(line, "CapEff"),
			strings.HasPrefix(line, "CapBnd"), strings.HasPrefix(line, "Seccomp"),
			strings.HasPrefix(line, "NoNewPrivs"):
			fmt.Println(strings.Join(strings.Fields(line), "\t"))
		}
	}
	for _, p := range []string{"/proc/self/uid_map", "/proc/self/gid_map", "/proc/self/setgroups"} {
		if b, err := os.ReadFile(p); err == nil {
			fmt.Printf("%s: %s\n", p, strings.TrimSpace(string(b)))
		}
	}
}
