# Upgrading Cryptlib behind the Mystic shim

The shim (`shim/libcl_shim.so`, installed as `libs/libcl.so`) translates the
Cryptlib 3.4.5 constants Mystic hard-codes into the numbering of one specific newer
Cryptlib (currently **3.4.9.x**). It checks the real library's version in
`cryptInit` and refuses to load on a mismatch, so a wrong pairing fails loudly:

* `mis` logs "Cryptlib not detected; SSL/SSH capabilities disabled"
* syslog/journal gets a line from `mystic-libcl-shim` naming both versions
  (`journalctl -t mystic-libcl-shim`)
* set `CL_SHIM_ALLOW_VERSION_MISMATCH=1` in `mis`'s environment to override
  (not recommended: wrong constants silently break SSH)

## Steps for a newer Cryptlib

1. **Get the sources** and note the version (`CRYPTLIB_VERSION` in `cryptlib.h`,
   e.g. 350 for 3.5.0).
2. **Dump the new constants.** `shim/vals_cryptlib_3.4.9.txt` shows the format
   (`NAME value` per line, plus a `CRYPTLIB_VERSION n` line). Generate one the
   same way: compile a throwaway C program that `printf`s every `CRYPT_*`
   enumerator from the new `cryptlib.h`. Keep the old 3.4.5 dump as is; it
   describes what Mystic sends and must not change.
3. **Regenerate the tables:**
   `python3 -I shim/gen_maps.py shim/vals_cryptlib_3.4.5.txt shim/vals_<new>.txt > shim/maps.h`
   Look at the diff of `maps.h`. A constant that disappeared maps to 0 (rejected),
   and any entry you didn't expect deserves a look.
4. **Check the function list.** Every function in `shim/shim.c` must still exist
   in the new library (`nm -D --defined-only libcl_real.so | grep crypt`).
5. **Rebuild the real library** (in a Debian 13 container to match the host's
   glibc) with the two project changes:
   * `-march=x86-64` in `tools/ccopts.sh` instead of upstream's
     `-march=x86-64-v3`, see `ccopts-baseline-x86-64.patch`. The live host is a
     "Common KVM processor" without AVX2/BMI2; v3 builds die with Mystic's
     "Runtime error 216".
   * CTR/X25519/ED25519 and the `ssh2_algo.c` write-side fix, see
     `ssh-ctr-ed25519.patch`. Don't enable `USE_SSH_EXTENDED`.
   Then confirm no CPU-specific instructions slipped in:
   `objdump -d libcl_real.so | grep -cE '\b(vpxor|vmovdqu|rorx|mulx|andn)\b'` must print 0.
6. **Rebuild the shim**: see the one-liner in `README.md` (gcc `-shared`, soname
   `libcl.so.3.4`, built in the same container).
7. **Test locally** with a copy of the live config before deploying: start `mis`,
   log in with `ssh -tt`, confirm the node starts and see
   `CL_SHIM_TRACE=/path ./mis daemon` for a trace of every translated call.
   Also test with syncterm's "allow early data" both on and off.
8. **Deploy** both files together (`libs/libcl.so` = shim, `libs/libcl_real.so` =
   real library), keep `libs/libcl.so.bak` for rollback, then
   `systemctl restart mystic-bbs.service`.

Roll back with `cp -p libs/libcl.so.bak libs/libcl.so` and a restart.
