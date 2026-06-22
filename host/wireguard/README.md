# WireGuard VPN (on the EdgeRouter)

Remote access to the home LANs via WireGuard, terminated **on the Ubiquiti
EdgeRouter-4 (EdgeOS v3.0.1)** — not a container. Chosen over a self-hosted mesh
(NetBird) for simplicity: runs on hardware we already own, no extra services to
maintain, excellent mobile support. **One peer per device** (9 today, across 4
household users) — never share a key between devices.

## Topology
- **Interface** `wg0` on the router, `10.10.10.1/24`, UDP **51820** (WAN = `eth0`).
- **Endpoint** `vpn.pdx.sanctioned.tech:51820` — a CNAME to the `firewall.pdx` A
  record, kept current by DDNS (the WAN IP is dynamic; see below).
- **Split tunnel** — clients route only the home LANs + tunnel over the VPN
  (`192.168.1.0/24, 192.168.2.0/24, 192.168.3.0/24, 10.10.10.0/24`); their normal
  internet stays direct. (Full-tunnel would need a `wg0 → WAN` masquerade rule — not
  set up.)
- **DNS** — clients use `10.10.10.1` (the router); `dnsmasq` listens on `wg0`
  (`service dns forwarding listen-on wg0`), so internal `*.pdx.sanctioned.tech`
  names resolve and external queries go through AdGuard, exactly like on-LAN.
- **Server public key** `<SERVER_PUBKEY>`

## Peers
One peer per device; naming convention `<user>-<device>`. Public keys are not secret,
but are omitted here (placeholders) since this is a public repo — the live values live
in the off-repo VPN working area's device registry.

| Peer            | Tunnel IP   | Public key |
|-----------------|-------------|------------|
| `user1-android` | 10.10.10.2  | `<PUBKEY>` |
| `user2-iphone`  | 10.10.10.3  | `<PUBKEY>` |
| `user3-iphone`  | 10.10.10.4  | `<PUBKEY>` |
| `user4-iphone`  | 10.10.10.5  | `<PUBKEY>` |
| `user3-macbook` | 10.10.10.6  | `<PUBKEY>` |
| `user2-macbook` | 10.10.10.7  | `<PUBKEY>` |
| `user2-ipad`    | 10.10.10.8  | `<PUBKEY>` |
| `user2-windows` | 10.10.10.9  | `<PUBKEY>` |
| `user4-ipad`    | 10.10.10.10 | `<PUBKEY>` |

Next free tunnel IP: **`10.10.10.11`**. (`.2/.3/.5` were the original per-*user* peers,
repurposed to each user's first device — same key, renamed.)

**Client configs contain private keys and are NOT in git.** They're generated +
managed in the operator's private VPN working area (off-repo) — see that area's
`vpn-admin.md` for the add/remove/rotate runbook and the device registry. Each person
imports by scanning their QR (`<peer>.png`) with the WireGuard app, or loading the
`<peer>.conf`. Distribute over a secure channel.

## EdgeOS config (reference — server private key omitted)
```
configure
set interfaces wireguard wg0 address 10.10.10.1/24
set interfaces wireguard wg0 listen-port 51820
set interfaces wireguard wg0 private-key <SERVER_PRIVATE_KEY>
set interfaces wireguard wg0 peer <PUBKEY> description <name>
set interfaces wireguard wg0 peer <PUBKEY> allowed-ips 10.10.10.N/32     # repeat per peer
set firewall name WAN_LOCAL rule 30 action accept
set firewall name WAN_LOCAL rule 30 protocol udp
set firewall name WAN_LOCAL rule 30 destination port 51820
set firewall name WAN_LOCAL rule 30 description WireGuard-VPN
set service dns forwarding listen-on wg0
commit ; save
```

## DDNS
The residential WAN IP is dynamic, so the `firewall.pdx.sanctioned.tech` A record
(and the `vpn.pdx` CNAME pointing at it) is kept current by
[`docker/ddns-easydns.sh`](../../docker/ddns-easydns.sh) — a 5-minute cron on jarvis
that updates the record via the EasyDNS REST API (reusing the ACME EasyDNS creds).

## Gotchas (hard-won — read before re-applying via SSH)
- **Non-interactive WireGuard commits** (fed to `vbash` via `script-template`) fail
  with `/vyatta-check-allowed-ips.pl: No such file` because `$vyatta_sbindir` is
  unset in that context. `export vyatta_sbindir=/opt/vyatta/sbin` before the commands.
- **Modifying an in-use firewall ruleset** (`WAN_LOCAL`) via `script-template` fails
  with `Cannot delete rule set "WAN_LOCAL" (still in use)`. Apply that change from an
  **interactive TTY** instead (`ssh -tt … vbash`, then `configure`/`set`/`commit`/
  `save`) or the GUI — the real commit path handles in-use rulesets. (`wg0` and DNS
  changes commit fine non-interactively with the `vyatta_sbindir` fix above.)
- **EasyDNS REST:** `POST /zones/records/{id}` *updates* a record; `PUT` is add-only
  and returns 404 for an update.

## Add / remove a peer
Tooling is split: the **firewall** has `wg` (keygen) but no `qrencode`; **jarvis** has
`qrencode` but no `wg`. So: generate keys on the firewall, render the QR on jarvis. The
off-repo VPN working area has an `add-device.sh` that automates the whole flow; the
manual steps:
- **Add:** name the peer `<user>-<device>`, pick the next free IP. On the firewall:
  `priv=$(wg genkey); pub=$(printf '%s' "$priv" | wg pubkey)` → `set interfaces
  wireguard wg0 peer <PUB> description <user>-<device>` + `... allowed-ips
  10.10.10.N/32`, commit (with the `vyatta_sbindir` fix). Build the client `.conf`
  (swap PrivateKey/Address), `qrencode -t png` it on jarvis, distribute securely.
- **Remove (revoke):** `delete interfaces wireguard wg0 peer <PUB>`, commit; delete the
  device's files in the off-repo working area. Do this immediately for a lost device.
