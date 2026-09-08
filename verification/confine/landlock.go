// Landlock support: mechanism M.
//
// The 2026-09-07 target run found a third mechanism the two-mechanism model
// could not express — writes are scoped by an LSM path allowlist, not by the
// ID map (paper §3.3, §3.7). This file models it, so every M observation can
// be reproduced locally instead of being taken on trust from a target
// transcript.
//
// One Landlock ruleset that *handles* the filesystem write rights and *grants*
// them only beneath the allowlisted directories reproduces all of it:
//
//   - writes outside the allowlist fail, writes inside succeed, while reads
//     work everywhere (only write rights are handled, so reads are unhandled
//     and therefore unrestricted);
//   - mount(2), move_mount(2), pivot_root(2) and umount2(2) fail EPERM,
//     because landlock's sb_mount/move_mount/sb_pivotroot/sb_umount hooks
//     return -EPERM whenever the domain handles *any* filesystem access
//     (security/landlock/fs.c, v6.18);
//   - opening anything for writing outside the allowlist fails EACCES from
//     hook_file_open — including /proc/<pid>/mem with O_RDWR.
//
// Requires CONFIG_SECURITY_LANDLOCK and landlock in the boot LSM list. When
// the kernel refuses, confine says so and exits rather than running a probe
// under a mechanism that is silently absent.
package main

import (
	"fmt"
	"os"
	"strings"
	"syscall"
	"unsafe"
)

// x86-64 syscall numbers, stable across architectures Landlock supports.
const (
	sysLandlockCreateRuleset = 444
	sysLandlockAddRule       = 445
	sysLandlockRestrictSelf  = 446
)

const landlockCreateRulesetVersion = 1 << 0

const landlockRulePathBeneath = 1

// Filesystem access rights, uapi/linux/landlock.h. The write set is
// everything that changes the tree; the read set is left unhandled so reads
// keep working everywhere, which is what the target does.
const (
	fsExecute    = 1 << 0
	fsWriteFile  = 1 << 1
	fsReadFile   = 1 << 2
	fsReadDir    = 1 << 3
	fsRemoveDir  = 1 << 4
	fsRemoveFile = 1 << 5
	fsMakeChar   = 1 << 6
	fsMakeDir    = 1 << 7
	fsMakeReg    = 1 << 8
	fsMakeSock   = 1 << 9
	fsMakeFifo   = 1 << 10
	fsMakeBlock  = 1 << 11
	fsMakeSym    = 1 << 12
	fsRefer      = 1 << 13 // ABI 2
	fsTruncate   = 1 << 14 // ABI 3
	fsIoctlDev   = 1 << 15 // ABI 5
)

// writeAccessABI1 is the write set every kernel with Landlock understands.
const writeAccessABI1 = fsWriteFile | fsRemoveDir | fsRemoveFile | fsMakeChar |
	fsMakeDir | fsMakeReg | fsMakeSock | fsMakeFifo | fsMakeBlock | fsMakeSym

// landlockABI returns the ruleset ABI the running kernel implements, or an
// error when Landlock is unavailable. A version query is the only way to ask;
// there is no /proc entry for it.
func landlockABI() (int, error) {
	r, _, e := syscall.Syscall(sysLandlockCreateRuleset, 0, 0, landlockCreateRulesetVersion)
	if e != 0 {
		return 0, e
	}
	return int(r), nil
}

// writeAccessFor widens the handled write set to what this ABI supports.
// Handling a right the kernel does not know returns EINVAL, so the set has to
// track the ABI rather than assume the newest one.
func writeAccessFor(abi int) uint64 {
	access := uint64(writeAccessABI1)
	if abi >= 2 {
		access |= fsRefer
	}
	if abi >= 3 {
		access |= fsTruncate
	}
	return access
}

// applyLandlock restricts this process to a filesystem write allowlist.
// paths is colon-separated; a path that does not exist is an error rather
// than a silent omission, because a missing grant reads exactly like a
// mechanism that denied something.
func applyLandlock(paths string) error {
	abi, err := landlockABI()
	if err != nil {
		return fmt.Errorf("landlock unavailable (%v): the kernel needs "+
			"CONFIG_SECURITY_LANDLOCK and landlock in lsm=", err)
	}
	access := writeAccessFor(abi)

	attr := struct{ HandledAccessFS uint64 }{HandledAccessFS: access}
	r, _, e := syscall.Syscall(sysLandlockCreateRuleset,
		uintptr(unsafe.Pointer(&attr)), unsafe.Sizeof(attr), 0)
	if e != 0 {
		return fmt.Errorf("landlock_create_ruleset: %v", e)
	}
	ruleset := int(r)
	defer syscall.Close(ruleset)

	for _, p := range strings.Split(paths, ":") {
		if p == "" {
			continue
		}
		const oPath = 0x200000 // O_PATH; not exported by syscall on linux/amd64
		fd, err := syscall.Open(p, oPath|syscall.O_CLOEXEC, 0)
		if err != nil {
			return fmt.Errorf("landlock: open %s: %v", p, err)
		}
		// struct landlock_path_beneath_attr is packed: u64 then s32.
		var rule [12]byte
		*(*uint64)(unsafe.Pointer(&rule[0])) = access
		*(*int32)(unsafe.Pointer(&rule[8])) = int32(fd)
		_, _, e := syscall.Syscall6(sysLandlockAddRule, uintptr(ruleset),
			landlockRulePathBeneath, uintptr(unsafe.Pointer(&rule[0])), 0, 0, 0)
		syscall.Close(fd)
		if e != 0 {
			return fmt.Errorf("landlock_add_rule %s: %v", p, e)
		}
	}

	if _, _, e := syscall.RawSyscall6(syscall.SYS_PRCTL,
		38 /* PR_SET_NO_NEW_PRIVS */, 1, 0, 0, 0, 0); e != 0 {
		return fmt.Errorf("no_new_privs: %v", e)
	}
	if _, _, e := syscall.Syscall(sysLandlockRestrictSelf, uintptr(ruleset), 0, 0); e != 0 {
		return fmt.Errorf("landlock_restrict_self: %v", e)
	}
	if os.Getenv("CONFINE_VERBOSE") == "1" {
		fmt.Fprintf(os.Stderr, "confine: landlock abi=%d write-allowlist=%s\n", abi, paths)
	}
	return nil
}
