# Firmware format notes

Dumping what I figured out about how this thing's firmware is actually put
together, mostly so I stop having to re-derive it if I come back to this in
six months.

## Hardware

- SoC: Broadcom BCM6755 (die ID BCM947622), quad-core ARM Cortex-A7, 32-bit
- Flash: 128MB SPI-NAND. Two 56MB firmware slots + 8MB `tp_data` + 8MB
  `data`. There's also a separate, much smaller region holding fixed-offset
  config partitions (`default-config`, `user-config`, `soft-version`, etc) -
  more on that below, it matters more than you'd think.
- Base OS: Linux 4.1.52 + TP-Link's "Iplatform" layer on top of an ancient
  OpenWrt Attitude-Adjustment-12.09-rc1-derived userland. Not real OpenWrt,
  don't let the directory names in the GPL tarball fool you.

## Firmware image anatomy (the full signed `.bin` TP-Link ships)

```
0x000000  4 bytes    total image size (big-endian)
0x000004  16 bytes   MD5 checksum (algorithm unsolved, see below)
0x000014  252 bytes  "fw-type:Cloud" text header, zero-padded
0x000110  32 bytes   magic token 1
0x000130  128 bytes  RSA-1024 signature
0x0001B0  240 bytes  magic token 2 + metadata hash
0x0002A0  3444 bytes 0xFF padding
0x001014  444 bytes  embedded support-list + soft-version strings
0x0011D0  ...        everything below here is the actual Broadcom payload
```

Everything from `0x0011D0` to the end - call it the "fsonly" blob - is:

```
[padded JFFS2 bootfs, exactly 4MB minus 256 bytes]
[BcmFsTag marker, 256 bytes - "BcmFs-ubifs\0" x4 + 0xFF padding]
[UBI rootfs image]
[addvtoken trailer, 20 bytes]
```

That 4MB-minus-256 + 256 split lines up suspiciously perfectly: it's exactly
32 flash eraseblocks (128KiB each), so the bootfs region clearly has to land
on an eraseblock boundary and the marker is just whatever's left over to pad
out to it. I never found the actual tool/invocation that produces exactly a
256-byte marker - TP-Link's own GPL-shipped `BcmFsTag` host tool always
produces `(spares+1) × eraseblock_size` bytes minimum, which can't land on
256 for any sane input. Whatever real build pipeline TP-Link uses internally
differs from what's in the public GPL drop. Didn't matter in the end: since
none of my changes touch the bootfs, I just dd'd this whole 4MB region
straight out of the stock `.bin` unmodified and reused it byte-for-byte.
The GPL tree's `BcmFsTag`/`addvtoken`/`mkfs.ubifs`/`ubinize` host tools
(under `hostTools/` and `hostTools/mtd-utils-2.0.1/`) are the exact ones
used to rebuild the UBI rootfs and re-wrap everything - they're x86 ELF
binaries meant to run on the build machine, not the router, and they're
32-bit so you need `dpkg --add-architecture i386` + the usual multilib libs
on a modern 64-bit build box.

## The outer header: still unsolved

I spent a while trying to reproduce the outer header's MD5 field so I could
build a fully-signed, stock-equivalent image instead of a headerless one.
No luck. The one documented algorithm I could find - OpenWrt's
`tplink-safeloader.c`, which has a hardcoded salt
(`7a2b15ed9b98596de504ab44ac2a9f4e`) and computes
`MD5(salt + file[0x14:])` - does NOT reproduce this device's actual header
MD5. That salt and formula is real (verified it against devices that
formula *does* work for, via that same source file), it's just not what
generated this header. The RSA signature is a non-starter regardless since
I don't have TP-Link's private key.

Good news: it doesn't matter. The router's own recovery-mode web page (the
one you get to by holding reset) happily accepts a headerless raw fsonly
blob - no "fw-type:Cloud" header at all - and flashes it as the active
firmware. I confirmed this with a byte-identical repackaging of stock
content through the exact same pipeline before ever touching the content
itself, specifically to rule out "maybe it just silently falls back to the
old slot and I'm fooling myself" - it wasn't, the content changes genuinely
take effect. Feeding it a header with a *wrong* MD5/signature gets flatly
rejected ("Upgrade failed. The file is invalid."), so there is some
validation happening - it just doesn't seem to require the header to be
present at all, only requires it to be *internally self-consistent* if you
bother including one. I don't have a serial console on this unit so I can't
tell you for certain whether this check lives in the browser-side recovery
page's own code or somewhere lower, but functionally: skip the header
entirely, it works.

## Partition quirks worth knowing about

- `soft-version` (the version string the web UI's System page shows) lives
  on a small, separate flash partition at a fixed offset, read via
  `nvrammanager -r ... -p soft-version`. It is **not** part of the
  bootfs/rootfs image you're flashing, so editing
  `etc/partition_config/soft-version` in your rootfs does nothing to what's
  displayed. If you want to change it, it's a runtime
  `nvrammanager -w <file> -p soft-version` call from an actual shell on the
  device, not a firmware-build-time edit.
- `default-config` / `user-config` are similarly separate small partitions.
  `factory_reset` restores `user-config` from `default-config`. I strongly
  suspect (not 100% confirmed) that live UCI config for at least some
  services is read from `user-config` rather than from the rootfs's own
  `/etc/config/*`, which is the whole reason the dropbear UCI approach
  silently did nothing - see `SSH-DEBUGGING.md`.
- CFE's TFTP/serial recovery console (strings-visible in the `cferam`
  blob: `Tag crc failed`, `Image crc failed`, a `f [[hostip:]filename]`
  TFTP command) checks a low-level Broadcom Tag/CRC format, not the
  TP-Link cloud header. Never actually tested flashing through it since
  the normal browser recovery page worked fine headerless, but it's there
  if the browser-based recovery page ever stops being an option.
