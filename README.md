# Archer AX1800 v1.20 - stripped firmware

De-cloud-ified firmware for the TP-Link Archer AX1800 v1.20 (same board as the
AX20 v1.20, FCC ID TE7AX20V1, Broadcom BCM6755). Built from TP-Link's own GPL
release plus the stock firmware, repacked with the TDDP debug backdoor and
the TP-Link cloud/account-redirect stack ripped out, and with working SSH
(which was not as free as you'd think - see `docs/SSH-DEBUGGING.md`).

This is not OpenWrt. OpenWrt does not have real support for this exact board.
There's a MediaTek router that also gets called "AX23 v1" /
"AX1800" that has great OpenWrt support, and it is NOT this board, do not get
them confused, the firmware will not boot (wrong CPU architecture entirely).
What's here is TP-Link's own vendor SDK, same Linux 4.1.52 / OpenWrt
Attitude-Adjustment-12.09-rc1-era base they shipped, just with the parts I
don't want running on my network cut out.

Tested against stock firmware **1.3.6 Build 20230830 rel.23076**. If you're
on a different build the strip list in `build/strip-list.txt` will probably
still mostly apply but go check the paths exist first, don't just run it
blind.

## What's actually gone

- `tddp` - the real TDDP debug protocol daemon. Launched from `/etc/rc.local`
  of all places, not from an init script, which is why it's easy to miss if
  you only check `/etc/rc.d`. This is the thing with the CVE history.
- The entire `cloud_*` binary family (cloud_download, cloud_upgrade,
  cloud_getDevToken, cloud_https_*, etc) plus the `cloud-brd` / `cloud-client`
  / `cloud-https` LAN-side helpers.
- `tmpServer` -  TP-Link's own "TMP" protocol for Tether-app device management
  (parental control device blocking etc). Proprietary, undocumented wire format.
- `pfclient` - HomeCare, TP-Link's cloud-subscription parental-control/
  malware-blocking thing. Phones home.
- `domain_login` + the `domain_dns.ko` / `domain_libs.ko` / `domain_redirect.ko`
  / `domain_tip.ko` kernel modules + `wportal.ko` - this is the DNS/HTTP
  hijack that redirects your browsing to a "set up your TP-Link cloud
  account" page until you do. Also handles an Alexa-smart-home domain
  injection thing nobody asked for.
- `wportalctrl`, `smart_home_report`, `smart_home_schedule`, `auto_upgrade`,
  `auto-reboot`, the `tddp_hook_*` helper scripts.

## What's NOT gone, on purpose

Everything else - Samba, FTP, the VPN servers (OpenVPN/PPTP/L2TP/IPsec),
UPnP, DLNA, parental/access control UI, and **OneMesh** (the `tdpServer`
binary - confusingly named almost identically to the tddp backdoor binary it
sits right next to in `/usr/bin`, but it's actually just mesh-network device
discovery and is completely unrelated). I left all of it in. If you want a
leaner box, that's a strip-list edit, not a design decision I made for you.

## SSH

Works. Took way longer to get working than it had any right to - four
separate, unrelated bugs stacked on top of each other, each one hiding the
next. Full writeup in `docs/SSH-DEBUGGING.md` because I couldn't find this
documented anywhere and I don't want the next person to burn the evening I
burned on it.

The short version if you just want to connect:

```
ssh -o HostKeyAlgorithms=ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa root@192.168.0.1
```

`HostKeyAlgorithms=ssh-rsa` has to be an exact override, not `+ssh-rsa`
appended to the default list - appending still works for most old-dropbear
devices but breaks on this one specifically, see the writeup.

## Building it yourself

1. Get TP-Link's GPL drop for your exact hardware version from their
   [GPL code center](https://www.tp-link.com/us/support/gpl-code/). You want
   `ax1800v1.20_GPL` or whatever the equivalent is for your model/version -
   this gives you the host tools (`mkfs.ubifs`, `ubinize`, `BcmFsTag`,
   `addvtoken`) that actually match what your device's bootloader expects.
   Don't substitute generic upstream mtd-utils, the geometry/marker format
   has to match exactly or it won't boot.
2. Pull your stock firmware `.bin` (download it from TP-Link, or dump it off
   a device you already have).
3. `pip install ubi_reader` (needs to run as root, or pass `-k` and it'll
   mess up permissions - see `build/build.sh`, it handles this).
4. `./build/build.sh /path/to/stock.bin /path/to/ax1800v1.20_GPL`
   It'll ask for a root password interactively (don't hardcode one in a
   script you're going to publish, obviously). Spits out
   `custom_fsonly.bin` when it's done.
5. Flash via the router's normal recovery-mode page (hold reset and wps when
   powering on, it drops into a rescue web UI at 192.168.0.1). The recovery
   page accepts this headerless image fine even though it rejects a mismatched
   real TP-Link header - see `docs/DEVICE-NOTES.md` for why that is and what I
   couldn't figure out.
6. You may need a factory reset after the first flash before things fully
   settle. I never nailed down exactly why. If someone figures it out, open
   an issue, genuinely curious.

## Standard disclaimer

This will probably work on other Archer AX1800 v1.20 / AX20 v1.20 units but
I've only ever flashed my own. You're writing raw firmware to a router over
TFTP-adjacent recovery mode, that can go wrong, keep a UART adapter handy if
you have one and don't do this to the only router standing between your
house and the internet. I'm not responsible if you end up with an expensive
paperweight.
