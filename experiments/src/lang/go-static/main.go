// The Go counterpart of rust-static/main.rs. Same three questions, same
// output shape, so the two are directly comparable.
//
// The interesting row is threads_at_main: the Go runtime starts several OS
// threads before main() is entered, and the kernel refuses
// unshare(CLONE_NEWUSER) to any multithreaded caller. That is paper §3.5's
// F11 — a Go probe reports EINVAL on a completely unrestricted host — and it
// is a property of the language runtime, not of the sandbox.
package main

import (
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"
)

func threads() int {
	b, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "Threads:") {
			n, _ := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(line, "Threads:")))
			return n
		}
	}
	return 0
}

func main() {
	fmt.Println("lang                go")
	fmt.Println("threads_at_main    ", threads())
	fmt.Println("GOMAXPROCS         ", runtime.GOMAXPROCS(0))
	if err := syscall.Unshare(syscall.CLONE_NEWUSER); err != nil {
		fmt.Printf("unshare(NEWUSER)    FAIL errno=%d\n", int(err.(syscall.Errno)))
	} else {
		fmt.Println("unshare(NEWUSER)    OK")
	}
}
