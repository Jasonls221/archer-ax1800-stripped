# Getting SSH working: four bugs deep

I did not expect this to be the hard part. Stripping the cloud stack out was
mostly just "find the binary, find what starts it, delete both, check
nothing else references it." SSH took way longer and every single fix
uncovered a new, completely unrelated failure underneath it. Writing this up
because I went looking for anyone else who'd hit this on a TP-Link Broadcom
box and found nothing.

Device context: dropbear `2019.78-2` per `opkg list-installed`, Linux
4.1.52, glibc 2.26. If your dropbear version differs some of this may not
apply, but the auth-logic bugs especially seem like they'd be old enough to
affect a lot of TP-Link's Broadcom lineup.

## Bug 1: dropbear never even starts

Flash the stripped firmware, `nmap` the router, port 22 just isn't there.
`/etc/init.d/dropbear`'s `keygen()` function generates BOTH an RSA and a DSS
host key before it'll let the daemon start. Problem: this specific dropbear
build has no DSS support compiled in at all (`strings` the binary, zero
hits for `ssh-dss`). DSS keygen fails every single time, `keygen()` never
succeeds, dropbear never starts. Stock firmware never exposes this because
stock also never has a real root password set (see Bug 3), so you'd never
get far enough to notice.

Fix: patched `keygen()` to only require the RSA key, synchronously, with a
`/tmp` fallback if `/etc` turns out not to be writable at the point this
runs. See `build/files/etc/init.d/dropbear`.

## Bug 2: still doesn't start, even with a valid key

Fixed the keygen, still no port 22. Turns out `config_foreach dropbear_start
dropbear` - the standard OpenWrt-style "read the `dropbear` section out of
`/etc/config/dropbear` and start the daemon with those options" dance -
silently iterates zero times on this device. I'm fairly convinced the live
UCI config for a bunch of services actually lives on a separate NAND
partition (`user-config`, distinct from the rootfs you're flashing) that
never gets populated with a `dropbear` section the way the shipped rootfs
copy implies it should. I never fully nailed this down, I just stopped
trusting `config_foreach` for this service and moved on.

Fix: skip the UCI dance entirely, call `service_start` directly with
hardcoded flags. Not elegant, but it means the fix doesn't depend on
whatever state that other partition happens to be in.

## Bug 3: "User account 'root' is locked"

With the daemon actually running (confirmed via `dropbear -F -E` so it logs
to the foreground instead of syslog - do this, it's the only way any of this
is debuggable), connecting got as far as a password prompt, then every
single attempt failed with dropbear logging this exact line regardless of
whether the password was right.

Pulled dropbear's own source (`svr-authpasswd.c`) to see what actually
triggers that message: it's logged when `crypt(password, stored_hash)`
returns `NULL`, i.e. when libc doesn't recognize `stored_hash` as a valid
salt/hash format at all. Not a bad password - a broken comparison.

Root cause: stock `/etc/passwd` has `root:x:...` - the `x` is the normal
"real hash lives in /etc/shadow" sentinel. Dropbear is clearly *supposed*
to fall back to a `getspnam()` shadow lookup when it sees that, but on this
build that lookup silently fails, and it ends up handing the literal
one-character string `"x"` to `crypt()` as if it were the hash. `crypt()`
chokes on a 1-character salt and returns NULL. Every password fails the
same way because it was never actually comparing against your password to
begin with.

Fix: put the real hash directly in `/etc/passwd`'s password field (the
old pre-shadow convention), so dropbear never needs the shadow lookup to
succeed in the first place. Kept the shadow copy too, doesn't hurt.

## Bug 4: auth succeeds, then "shell request failed"

Got past Bug 3, `Password auth succeeded for 'root'` shows up in the log -
and then the client gets `PTY allocation request failed` /
`shell request failed` and the connection just closes. `devpts` was mounted
fine, `/dev/ptmx` existed with sane permissions, nothing in `dmesg`.

Turned out dropbear's own `--help` / usage text (pull it with `strings` on
the binary, it's not in any upstream dropbear doc because it's not an
upstream flag) lists:

```
-L    Enable SSH session login
-C    Use Web Server account login
```

Neither of those exist in mainline dropbear. TP-Link patched them in. `-L`
is apparently required or shell/PTY channel requests get silently refused
*after* auth already succeeded - which is a genuinely strange place to
gate that, but there it is.

Fix: added `-L` to the permanent startup flags. That's the whole fix, one
flag, three other bugs deep.

## The actual client-side gotcha

Separately, and unrelated to anything above: a modern OpenSSH client will
refuse this dropbear's host key outright unless you add `ssh-rsa` back to
`HostKeyAlgorithms` (removed from the default list a few years back over
SHA-1). Using `-o HostKeyAlgorithms=+ssh-rsa` (append) gets you past that
rejection, but then the connection resets mid key-exchange anyway -
`Connection reset by ... port 22` right after `expecting
SSH2_MSG_KEX_ECDH_REPLY`.

Cause: `+ssh-rsa` appends to OpenSSH's full modern default list, so
`ssh-rsa` ends up as roughly the 20th algorithm in a list full of names this
2019-era dropbear has never heard of (`sk-ecdsa-sha2-nistp256@openssh.com`,
post-quantum KEX entries, etc). Whatever dropbear's host-key-algorithm
matching code is doing, it falls over on a list that long with `ssh-rsa`
buried at the end of it, even though it handles a short list containing the
exact same algorithm name just fine.

Use `-o HostKeyAlgorithms=ssh-rsa` - no `+`, full override - so the client
only ever offers the one algorithm the server understands:

```
ssh -o HostKeyAlgorithms=ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa root@192.168.0.1
```

## How I actually found all this

Worth writing down since it's probably the more reusable part. I didn't
have serial/UART wired up, and the normal OpenWrt telnet failsafe
(`/bin/login.sh`) deliberately refuses to work once a root password is set
- which it was, since setting one was the whole point. So temporarily:

1. Patched `login.sh` to drop straight into a root shell over telnet, no
   auth at all, LAN-only, clearly banner-labeled as a diagnostic build.
2. Used that shell to run `dropbear -F -E ...` in the foreground, which
   logs everything straight to the terminal instead of (normally) vanishing
   into whatever syslog destination isn't being watched.
3. Triggered the real failure from another machine, watched what dropbear
   actually printed, fixed the one specific thing, rebuilt, repeated.

Four rebuild-flash-retest cycles, each one about 15 seconds of actual new
information. Put the telnet backdoor back to stock behavior the moment SSH
was confirmed solid - it was never meant to ship, it was a debugging
scaffold, and "open unauthenticated root shell" is a bad permanent feature
on a box whose whole point was removing backdoors.
