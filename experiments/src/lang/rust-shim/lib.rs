// An LD_PRELOAD interposer in Rust, of the shape podbox's `interpose` tier
// needs (paper §5.5, §10.3): override one libc symbol, record that it was
// reached, and return success without performing the operation — which is
// what makes ownership restoration survivable on a runtime that answers
// chown-to-an-unmapped-id with EINVAL (§9.1).
//
// Built as a cdylib. Two details decide whether this works at all, and both
// are the reason this file exists as a measurement rather than an assertion:
//
//   * `#[no_mangle] pub unsafe extern "C"` puts the symbol in .dynsym under
//     its C name, which is what the dynamic linker resolves against.
//   * the crate must not need Rust runtime initialisation to run this
//     function; there is none to run, because nothing here touches std's
//     lazily-initialised state beyond a raw write(2).
//
// Deliberately no `std::println!`: a preloaded library that allocates or
// takes a lock during an interposed call can deadlock the host process.
#![allow(clippy::missing_safety_doc)]

use core::ffi::{c_char, c_int};

unsafe extern "C" {
    fn write(fd: c_int, buf: *const u8, n: usize) -> isize;
}

const NOTE: &[u8] = b"rust-shim: intercepted lchown\n";

#[unsafe(no_mangle)]
pub unsafe extern "C" fn lchown(_path: *const c_char, _uid: u32, _gid: u32) -> c_int {
    unsafe { write(2, NOTE.as_ptr(), NOTE.len()) };
    0 // report success without changing ownership: the fakeroot manoeuvre
}
