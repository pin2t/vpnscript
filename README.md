# vpnscript

Three scripts that turn a bare Ubuntu 24+ / Debian 13 box into a self-hosted VPN
server with two independent entry points, and hand you the client configs.

```bash
./install.sh root@203.0.113.10
```

| | |
|---|---|
| **AmneziaWG 3.1** | WireGuard with DPI-resistant obfuscation and encrypted packet headers, on a random UDP port in 1200–2000 |
| **Xray VLESS** | XHTTP transport wrapped in REALITY, on a random TCP port in 1200–2000 |
| **DNS** | both tunnels resolve through the server, which forwards upstream over DNS-over-HTTPS |

Two protocols because they fail differently: AmneziaWG is a fast full-device
tunnel that survives UDP-based DPI, while Xray/REALITY is indistinguishable
from a TLS session to a real website and gets through where UDP is blocked
outright. The same client name exists on both, so anyone can switch.

**Client configs are never stored on the server.** Keys are generated, streamed
to your machine over the ssh session, and dropped. The server keeps only what
the daemons need to recognise a client: a WireGuard peer and a VLESS uuid.

## Requirements

* On your machine: `bash`, `ssh`, `awk`. macOS and Linux both work.
* On the server: a fresh Ubuntu 24.04+ or Debian 13 host, root over ssh with
  your key already installed, and outbound internet access.

Everything else is installed by `install.sh`.

## Usage

### install.sh — set up the server and get 10 configs

```bash
./install.sh root@203.0.113.10
```

Picks two random free ports, builds and installs AmneziaWG and Xray, wires up
DNS, creates 10 clients (`client01` … `client10`) and writes their configs to
`./configs/203.0.113.10/`. Expect it to take a few minutes: a Go toolchain is
fetched to build AmneziaWG from source.

```
  -o, --output DIR       where to write configs (default: ./configs/<host>)
  -n, --clients N        how many client profiles (default: 10)
  -e, --endpoint HOST    address clients dial (default: the ssh host)
      --prefix NAME      client name prefix (default: client)
      --sni DOMAIN       REALITY camouflage domain (default: www.cloudflare.com)
      --doh URL[,URL]    DoH upstreams (default: Cloudflare, then Quad9)
      --min-client-ver V lowest Xray-core version allowed over REALITY
      --force            wipe an existing install and start over
```

Re-running `install.sh` on a host that already has it refuses to proceed, because
regenerating the server keys would invalidate every config you handed out. Use
`add.sh` for more clients, or `--force` if you really want a clean slate.

Use `--endpoint` when the address clients should dial is not the one you ssh to
(a NAT'd box, a hostname you would rather bake into the configs, a jump host).

### add.sh — issue one more client

```bash
./add.sh root@203.0.113.10           # next free name: client11
./add.sh root@203.0.113.10 laptop    # or name it yourself
```

Creates an AmneziaWG peer and an Xray user under the same name, downloads the
three files, keeps nothing on the server.

### remove.sh — revoke a client

```bash
./remove.sh root@203.0.113.10 configs/203.0.113.10/client04.conf
```

Identifies the client from the config file — an AmneziaWG `.conf` by its key, an
`.xray.json` or `.vless.url` by its uuid — and deletes it. Because the files
issued by these scripts also carry the client's name, one file is enough to
revoke that client from **both** protocols.

```
      --name CLIENT   revoke by name instead, if you no longer have the config
      --only WHICH    limit to "awg" or "xray" (default: both)
```

Your local copies are left alone; delete them when you are done with them.

## What you get per client

| file | what to do with it |
|---|---|
| `<name>.conf` | AmneziaWG. Import into the AmneziaVPN app, or `awg-quick up <name>` on Linux. |
| `<name>.vless.url` | A `vless://` link. Paste into v2rayN, NekoBox, Hiddify, streisand, … |
| `<name>.xray.json` | The same Xray client as a full config: `xray run -c <name>.xray.json`, then point apps at the SOCKS proxy on `127.0.0.1:10808` or HTTP on `127.0.0.1:10809`. |

All three are written mode `600` — they contain private keys.

## How the DNS works

Xray runs a plain-DNS listener on the server's tunnel address (`10.x.y.1:53`) and
resolves everything it is asked over DNS-over-HTTPS.

* **AmneziaWG clients** get `DNS = 10.x.y.1` in their profile, so the whole
  device resolves through the tunnel.
* **Whatever the client is actually configured to use**, every packet to port 53
  entering the tunnel is redirected to that resolver — by a DNAT rule for
  AmneziaWG, and by a routing rule for Xray. This matters: plenty of clients
  ignore a pushed DNS, and a `vless://` share link cannot carry one at all.
  Without the redirect those clients send cleartext queries straight out of the
  server, which both leaks and fails wherever their own resolver is blocked.
* Names that the server resolves on a client's behalf (anything the VLESS
  outbound connects to by hostname) go over DoH as well.

No cleartext DNS leaves the server. `A`/`AAAA` queries are answered from the DoH
upstream; other record types get an empty answer rather than being forwarded in
the clear, so `MX`, `TXT` and `PTR` lookups through the tunnel come back empty.

Change the upstream with `--doh`. Use IP-literal URLs (`https://1.1.1.1/dns-query`,
`https://9.9.9.9/dns-query`) so no bootstrap resolution is needed.

## Things worth knowing

**Client app version.** REALITY in current Xray refuses clients whose core is
older than v26.3.27, and upstream deliberately keeps that floor high — an older
client is easier to fingerprint. If a phone app fails to connect while
`xray run -c <name>.xray.json` works, its bundled core is too old: update the
app, or reinstall with `--min-client-ver 25.1.1` to accept it. Lowering it
somewhat increases the odds of the server's IP being flagged.

**Non-443 ports.** You asked for random ports in 1200–2000, and that is what you
get. Xray will note in its log that REALITY on a non-443 port is more
conspicuous to a censor than on 443 — an inherent trade-off of the port range,
not a misconfiguration.

**IPv6.** If the server has working IPv6, the tunnel is dual-stack and NATs v6
too. If it does not, clients still route `::/0` into the tunnel, where it is
dropped — so v6 traffic cannot leak around the VPN — and the resolver answers
`AAAA` queries with an empty record, so nothing hands a client an address it has
no route to.

**Running a client profile on the server itself** repoints the machine's own
resolver at the tunnel, because `resolvconf` state is not per-namespace. If you
want to test a profile on the VPN host, strip the `DNS =` line from it first.

**AmneziaWG 3.1.** On top of the 2.x junk packets, message paddings and header
values, 3.x encrypts the low-entropy header fields under a `HeaderProtectionKey`
shared by both ends, and pads every transport packet by a random amount. The
cipher takes its nonce from the `S1`–`S4` padding, so the generated values never
fall below 12. Both ends must speak 3.x: an older client, or one that lacks the
key, will not complete a handshake. The build tracks the newest `v3.1.*` tag of
`amneziawg-go` and `amneziawg-tools`; override with `VS_AWG_GO_REF` /
`VS_AWG_TOOLS_REF` to pin something else.

**Kernel module.** AmneziaWG runs on the userspace `amneziawg-go` datapath rather
than a DKMS kernel module. That is deliberate: it behaves identically on Ubuntu
and Debian, survives kernel upgrades, and needs nothing from Secure Boot. It
costs some throughput on very fast links.

## On the server

| path | what |
|---|---|
| `/etc/vpnscript/server.env` | ports, keys, subnets — the state `add.sh` and `remove.sh` read |
| `/etc/amnezia/amneziawg/awg0.conf` | AmneziaWG interface and peers |
| `/usr/local/etc/xray/config.json` | Xray inbounds, users, DNS and routing |
| `/usr/local/sbin/vpnscript-firewall` | idempotent iptables/NAT/DNS-redirect rules, re-applied at boot; `vpnscript-firewall flush` removes them |
| `/etc/sysctl.d/99-vpnscript.conf` | forwarding and non-local bind |

Services: `awg-quick@awg0`, `xray`, `vpnscript-firewall`.

```bash
ssh root@203.0.113.10 'awg show; systemctl status xray --no-pager'
ssh root@203.0.113.10 'journalctl -u xray -n 50 --no-pager'
```

Both installs are verified from the outside in: the scripts check that the
services are active, that the interface came up, and that the tunnel resolver
answers a real query before reporting success.

## Layout

```
install.sh  add.sh  remove.sh     entry points, run on your machine
lib/common.sh                     local helpers (ssh, payload splitting)
lib/remote-common.sh              server-side library, shared by all three
lib/remote-{install,add,remove}.sh  the payloads piped into `ssh … bash -s`
```

Nothing is installed on your machine and nothing but the payload is copied to the
server: each script concatenates the library with its payload and pipes it into a
single ssh session. Server progress arrives on stderr, client files on stdout.
