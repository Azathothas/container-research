// Bogus-argument probes: separating "the filter refused" from "the kernel
// refused".
//
// A seccomp filter sees the syscall number and the six argument registers. It
// cannot dereference a pointer, and it runs before the syscall body. So a
// syscall called with an argument the kernel would reject *inside* the body
// discriminates the two mechanisms in one call:
//
//	a path-shaped errno (ENOENT, EBADF, ESRCH)  the syscall executed
//	EPERM for the same bogus argument           it was refused before entry
//
// This is the technique the 2026-09-07 second target session used to attribute
// move_mount's denial to an LSM rather than the filter, and to add
// process_vm_readv/writev to the filter's verified deny list (paper §3.7a).
// It lived only in ad-hoc C on the target; it belongs in the instrument.
//
//	probe attribute    run every discriminating probe, one child each
package main

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

const (
	sysMoveMount             = 429
	sysFsopen                = 430
	sysFsconfig              = 431
	sysFsmount               = 432
	sysOpenTree              = 428
	sysProcessVMReadv        = 310
	sysSeccomp               = 317
	sysLandlockCreateRuleset = 444

	fsconfigCmdCreate   = 6
	openTreeClone       = 1 // OPEN_TREE_CLONE
	moveMountFEmptyPath = 0x00000004
	atFdcwd             = ^uintptr(0) - 99 // AT_FDCWD (-100) as uintptr

	seccompSetModeFilter         = 1
	seccompFilterFlagNewListener = 1 << 3
)

// bogus is a path that cannot exist. A syscall that resolves paths and is not
// filtered must answer ENOENT for it.

func bogusPtr() uintptr { return cstr("/proc/self/nonexistent-probe-path") }

// attrChecks are ordered; each runs in its own child like the census.
var attrChecks = map[string]func() error{
	// Filtered, or executed? mount(2) resolves its target, so an unfiltered
	// kernel answers ENOENT here and a filtered one answers EPERM.
	"mount(2) bogus target": func() error {
		return raw(syscall.SYS_MOUNT, cstr("none"), bogusPtr(), cstr("tmpfs"), 0, 0)
	},
	"umount2(2) bogus target": func() error {
		return raw(syscall.SYS_UMOUNT2, bogusPtr(), 0)
	},
	"pivot_root(2) bogus paths": func() error {
		return raw(syscall.SYS_PIVOT_ROOT, bogusPtr(), bogusPtr())
	},
	// ESRCH from an unfiltered kernel; EPERM means the filter named it.
	"process_vm_readv(bogus pid)": func() error {
		var buf [1]byte
		local := [2]uintptr{uintptr(unsafe.Pointer(&buf[0])), 1}
		remote := [2]uintptr{0x1000, 1}
		return raw(sysProcessVMReadv, 999999,
			uintptr(unsafe.Pointer(&local[0])), 1,
			uintptr(unsafe.Pointer(&remote[0])), 1, 0)
	},
	// EBADF/ESRCH from an unfiltered kernel: the controls for the row above.
	"pidfd_getfd(-1,-1) [control]": func() error { return raw(438, ^uintptr(0), ^uintptr(0), 0) },
	"kcmp(-1,-1,...) [control]":    func() error { return raw(312, ^uintptr(0), ^uintptr(0), 0, 0, 0) },

	// The new mount API. fsmount(2) opens with the same may_mount() check
	// move_mount(2) and unshare(CLONE_NEWNS) use (fs/namespace.c, v6.18), so
	// its success proves the capability check passes and any move_mount
	// denial is downstream of it.
	"fsopen(tmpfs)": func() error {
		fd, err := fsopenTmpfs()
		if err != nil {
			return err
		}
		syscall.Close(fd)
		return nil
	},
	"fsmount(tmpfs)": func() error {
		mfd, err := fsmountTmpfs()
		if err != nil {
			return err
		}
		syscall.Close(mfd)
		return nil
	},
	"open_tree(/tmp, CLONE)": func() error {
		r, _, e := syscall.Syscall6(sysOpenTree, atFdcwd, cstr("/tmp"),
			openTreeClone, 0, 0, 0)
		if e != 0 {
			return e
		}
		syscall.Close(int(r))
		return nil
	},
	// ENOENT proves move_mount executes; the EPERM the attach rows report is
	// therefore kernel-internal, and do_move_mount() has no EPERM site.
	"move_mount(-> bogus dest)": func() error {
		mfd, err := fsmountTmpfs()
		if err != nil {
			return err
		}
		defer syscall.Close(mfd)
		return raw(sysMoveMount, uintptr(mfd), cstr(""), atFdcwd,
			bogusPtr(), moveMountFEmptyPath)
	},
	"move_mount(-> /tmp/mm-probe)": func() error {
		mfd, err := fsmountTmpfs()
		if err != nil {
			return err
		}
		defer syscall.Close(mfd)
		os.Mkdir("/tmp/mm-probe", 0o755)
		return raw(sysMoveMount, uintptr(mfd), cstr(""), atFdcwd,
			cstr("/tmp/mm-probe"), moveMountFEmptyPath)
	},
	// A detached mount an LSM cannot resolve a path for is unusable even
	// though its own permissions would allow the open.
	"openat(detached tmpfs, O_DIRECTORY)": func() error {
		mfd, err := fsmountTmpfs()
		if err != nil {
			return err
		}
		defer syscall.Close(mfd)
		r, _, e := syscall.Syscall6(syscall.SYS_OPENAT, uintptr(mfd), cstr("."),
			syscall.O_RDONLY|syscall.O_DIRECTORY, 0, 0, 0)
		if e != 0 {
			return e
		}
		syscall.Close(int(r))
		return nil
	},

	// The supervisor tier's three legs (paper §3.7a, §10.3).
	"seccomp(NEW_LISTENER)": func() error {
		fd, err := newListener()
		if err != nil {
			return err
		}
		syscall.Close(fd)
		return nil
	},
	"open /proc/self/mem O_RDONLY": func() error {
		fd, err := syscall.Open("/proc/self/mem", syscall.O_RDONLY, 0)
		if err != nil {
			return err
		}
		syscall.Close(fd)
		return nil
	},
	"open /proc/self/mem O_RDWR": func() error {
		fd, err := syscall.Open("/proc/self/mem", syscall.O_RDWR, 0)
		if err != nil {
			return err
		}
		syscall.Close(fd)
		return nil
	},
	// Reports the ABI rather than a verdict: it says whether an LSM of the
	// class that explains mechanism M is even present on this kernel.
	"landlock_create_ruleset(VERSION)": func() error {
		r, _, e := syscall.Syscall(sysLandlockCreateRuleset, 0, 0, 1)
		if e != 0 {
			return e
		}
		fmt.Printf("%-34s (ABI %d)\n", "  landlock", int(r))
		return nil
	},
}

var attrOrder = []string{
	"mount(2) bogus target", "umount2(2) bogus target", "pivot_root(2) bogus paths",
	"process_vm_readv(bogus pid)", "pidfd_getfd(-1,-1) [control]", "kcmp(-1,-1,...) [control]",
	"fsopen(tmpfs)", "fsmount(tmpfs)", "open_tree(/tmp, CLONE)",
	"move_mount(-> bogus dest)", "move_mount(-> /tmp/mm-probe)",
	"openat(detached tmpfs, O_DIRECTORY)",
	"seccomp(NEW_LISTENER)", "open /proc/self/mem O_RDONLY", "open /proc/self/mem O_RDWR",
	"landlock_create_ruleset(VERSION)",
}

func fsopenTmpfs() (int, error) {
	r, _, e := syscall.Syscall(sysFsopen, cstr("tmpfs"), 0, 0)
	if e != 0 {
		return -1, e
	}
	return int(r), nil
}

func fsmountTmpfs() (int, error) {
	fd, err := fsopenTmpfs()
	if err != nil {
		return -1, err
	}
	defer syscall.Close(fd)
	if _, _, e := syscall.Syscall6(sysFsconfig, uintptr(fd), fsconfigCmdCreate,
		0, 0, 0, 0); e != 0 {
		return -1, e
	}
	r, _, e := syscall.Syscall(sysFsmount, uintptr(fd), 0, 0)
	if e != 0 {
		return -1, e
	}
	return int(r), nil
}

// newListener installs an allow-everything filter carrying a notification
// listener. It changes the caller irreversibly, which is why every check runs
// in its own child.
func newListener() (int, error) {
	filter := []struct {
		Code uint16
		Jt   uint8
		Jf   uint8
		K    uint32
	}{{0x06, 0, 0, 0x7fff0000}} // BPF_RET|BPF_K, SECCOMP_RET_ALLOW
	prog := struct {
		Len    uint16
		_      [6]byte
		Filter unsafe.Pointer
	}{Len: 1, Filter: unsafe.Pointer(&filter[0])}
	if _, _, e := syscall.RawSyscall6(syscall.SYS_PRCTL, 38, 1, 0, 0, 0, 0); e != 0 {
		return -1, e
	}
	r, _, e := syscall.RawSyscall(sysSeccomp, seccompSetModeFilter,
		seccompFilterFlagNewListener, uintptr(unsafe.Pointer(&prog)))
	if e != 0 {
		return -1, e
	}
	return int(r), nil
}
