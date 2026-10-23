# Modern SSH for Mystic BBS

Mystic BBS does all of its SSH through [Cryptlib](https://cryptlib.com)
(`libs/libcl.so`). The library most installs use is years old and only offers
CBC ciphers, which current SSH clients increasingly refuse.

Swapping in a current Cryptlib doesn't work by itself, for two reasons this
installer solves:

1. Cryptlib renumbered constants (session attributes, session and keyset types)
   between 3.4.5 and 3.4.9. Mystic has the old numbers compiled in, so it asks
   for the wrong things. A small **shim** library sits in between and translates.
2. Upstream Cryptlib 3.4.9 builds for CPUs with AVX2/BMI2 by default. On VPS/KVM
   guests with a basic virtual CPU it dies with "Runtime error 216". The
   installer builds a plain x86-64 version.

It also enables AES-CTR ciphers, which upstream builds but silently doesn't
offer (an upstream bug, patched here).

Result: modern clients negotiate `aes128-ctr`/`aes256-ctr` with `hmac-sha2-256`
instead of CBC only. The host key is unchanged, so users see no warning.

## Use

    ./install.sh                 # builds, then asks where Mystic is
    ./install.sh -d /mystic      # same, non-interactive about the location
    ./install.sh --no-install    # just build (files land in ./dist/<arch>)
    ./install.sh --install-only -d /mystic    # install an earlier build
    ./install.sh --restore -d /mystic         # undo: put the original library back

When asked for the directory it uses `whiptail`, else `dialog`, else a plain prompt;
`--no-ui` forces the plain prompt. If a running `mis` is found its directory is
suggested.

After installing, **restart mis** (`systemctl restart mystic-bbs.service`, or
`mis shutdown` then `mis daemon`) and, in SyncTERM, enable **Allow early data**
for the BBS: the server starts sending the BBS screen before the client has
finished opening its channel, and without that setting SyncTERM drops it and
shows a blank screen.

## What it does

1. Checks for `gcc`, `make`, `patch`, `git` (or `curl`/`wget`), zlib headers.
2. Downloads Cryptlib at a pinned commit (3.4.9.6), verifying the commit hash.
   `--source DIR` uses an existing tree for offline builds.
3. Applies two patches (`payload/*.patch`) and builds.
4. Fails the build if the result needs AVX/BMI or is missing a function Mystic uses.
5. Builds the shim and runs a self-test (load, version check, create a cipher context).
6. Only then touches Mystic: backs up `libs/libcl.so` as `libcl.so.bak`
   (never overwritten; later backups get a timestamp), installs `libs/libcl.so`
   (shim) and `libs/libcl_real.so` (Cryptlib).

Nothing outside the chosen Mystic dir and the output dir is modified; the
temporary build directory is removed on success.

## Safety

* The shim checks that the Cryptlib it loads is the version it was generated for.
  If not (say someone later drops in a different `libcl_real.so`), SSH is disabled
  with a clear message (`mis` log + `journalctl -t mystic-libcl-shim`) instead of
  misbehaving.
* The installer checks that Mystic's binaries match the library's CPU
  architecture, and warns if the Mystic version isn't the tested one (A49).

## Limits

* Linux only. Tested on x86-64 with Mystic 1.12 A49; the other architectures
  Mystic supports should build but are untested.
* RSA host key (what Mystic generates) means DH group-exchange key exchange.
  No GCM/ChaCha20 or post-quantum key exchange; OpenSSH will still print its
  post-quantum warning.
* To support a newer Cryptlib later, see `UPGRADING.md`
  (regenerate `payload/maps.h`, re-check the patches).
