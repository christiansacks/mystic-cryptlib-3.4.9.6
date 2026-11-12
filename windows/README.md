# Modern SSH for Mystic BBS on Windows (32-bit)

The Windows version of this project: Cryptlib 3.4.9.6 plus a translation
shim, for Mystic 1.12 A49 on 32-bit Windows (Windows 7 or later). Windows
Mystic loads Cryptlib as `cl32.dll` from the Mystic folder.

Result is the same as on Linux: SSH clients negotiate `aes128-ctr`/`aes256-ctr`
with `hmac-sha2-256` instead of CBC only.

## Files

| File | What it is |
| --- | --- |
| `cl32.dll` | The shim. Mystic loads it; it translates the Cryptlib 3.4.5 constants Mystic has compiled in (`../payload/maps.h`) and forwards every call to `cl349.dll`. |
| `cl349.dll` | Cryptlib 3.4.9.6, built with MinGW (needs only `msvcrt.dll`, no Visual C++ runtime; plain i686, no SSE/AVX requirement). |
| `cltest.exe` | Optional check to run on the Windows box: loads both DLLs, starts Cryptlib, makes a key. Every line should end in `0`. |

## Build (on Linux)

    sudo apt install gcc-mingw-w64-i686 make patch git
    cd windows
    bash build-windows.sh         # files land in windows/dist/win32

The script downloads the pinned Cryptlib commit, applies
`../payload/ssh-ctr-ed25519.patch` and `payload/ssh-auth-unoffered-method.patch`,
builds the library, the shim and `cltest.exe`, and checks the result.

## Install

1. Shut Mystic down (`mis.exe` and all nodes); `cl32.dll` is locked while it runs.
2. Rename the existing `cl32.dll` to `cl32.dll.pre-349`.
3. Copy `cl32.dll` and `cl349.dll` into the Mystic folder.
4. Start Mystic. The MIS log should not say "Cryptlib not detected".

In SyncTERM, enable **Allow early data** for the BBS if the screen stays blank
after login (same as on Linux).

**Undo:** shut Mystic down, delete `cl32.dll` and `cl349.dll`, rename
`cl32.dll.pre-349` back to `cl32.dll`.

## What's different from the Linux build

* **Calling convention.** Windows Cryptlib exports are `__stdcall`, where the
  called function pops its own arguments. The Linux shim's "pass six words
  through" trick would corrupt the stack, so `payload/shim-win.c` gives every
  function its exact argument count. Same translation tables, same version check.
* **Stack alignment.** Mystic is built with Free Pascal, which calls DLLs with
  the stack only 4-byte aligned. Cryptlib 3.4.9 checks alignment internally, so
  a normal MinGW build fails in Mystic with `cryptInit` = -16 (internal error)
  and Mystic reports "Cryptlib not detected" (while a C test program works).
  Everything is built with `-mincoming-stack-boundary=2`.
* **Login methods.** `payload/ssh-auth-unoffered-method.patch`: when a client
  asks for a login method the server doesn't offer, unpatched 3.4.9 drops the
  connection ("Unknown user-authentication method 'publickey'"). SyncTERM tries
  `publickey` first, so it couldn't log in, and Mystic's auto-ban then banned
  the caller. With the patch Cryptlib answers like any SSH server (RFC 4252
  5.1, "methods that can continue: password") and the client carries on.
  OpenSSH and PuTTY send a `none` query first, so they weren't affected.
  This is not Windows-specific; the Linux build probably needs it too.
* **Build fixes for MinGW:** `make OSNAME=win32 target-init` (Windows entropy
  source), `-DNO_ASM` (the x86 assembler is MSVC-only), an `endian.h` for the
  cross compiler, and `compat.c` for `IsWindowsXPOrGreater`, which MinGW
  only provides inline. The test objects don't build under MinGW and aren't needed.

## Troubleshooting

If `cl32.dll` can't load `cl349.dll`, or `cl349.dll` is not 3.4.9, the shim
writes `cl32shim.log` in the Mystic folder and Mystic disables SSH/SSL instead
of misbehaving. Set the environment variable `CL_SHIM_TRACE` to a file name
before starting `mis.exe` to log every call the shim forwards.

## Tested

Mystic 1.12 A49 on Windows 7 32-bit (Shadowscope BBS): SSH logins with
SyncTERM and PuTTY. Under Wine, calling with Mystic's 3.4.5 constants and a
4-byte aligned stack: SSH server with OpenSSH 9.6 (password; key then
password) and with a client that sends `publickey` first; a keyset created by
the old 3.4.5 `cl32.dll` read back through the shim; a TLS 1.2 server session.

Windows port by Captain Obvious, Shadowscope BBS.
