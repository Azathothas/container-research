// The three properties podbox needs from its implementation language, probed
// from the language itself rather than from its documentation:
//
//   1. how many OS threads the runtime starts before main() runs — because
//      unshare(CLONE_NEWUSER) is refused for any multithreaded caller, and
//      PR_SET_PDEATHSIG fires on the death of the creating *thread*
//      (paper §3.5, §10.6);
//   2. whether unshare(CLONE_NEWUSER) is therefore usable at all;
//   3. whether the binary carries a PT_INTERP, i.e. whether it needs a loader
//      at the far end (paper §8.4's memfd rung requires that it does not).
//
// Property 3 is read off the artefact by the calling script, not self-reported.
use std::fs;

const CLONE_NEWUSER: i32 = 0x1000_0000;

fn threads() -> usize {
    fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("Threads:"))
                .and_then(|l| l.split_whitespace().nth(1).map(|n| n.to_string()))
        })
        .and_then(|n| n.parse().ok())
        .unwrap_or(0)
}

fn main() {
    println!("lang                rust");
    println!("threads_at_main     {}", threads());
    let rc = unsafe { libc_unshare(CLONE_NEWUSER) };
    if rc == 0 {
        println!("unshare(NEWUSER)    OK");
    } else {
        println!("unshare(NEWUSER)    FAIL errno={}", errno());
    }
}

// Declared by hand rather than pulling the libc crate: this probe must build
// with no network and no registry, exactly as it would on the target.
unsafe extern "C" {
    #[link_name = "unshare"]
    fn libc_unshare(flags: i32) -> i32;
    #[link_name = "__errno_location"]
    fn errno_location() -> *mut i32;
}

fn errno() -> i32 {
    unsafe { *errno_location() }
}
