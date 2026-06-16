# WireGuard VPN (on the EdgeRouter)

Remote access to the home LANs via WireGuard, terminated **on the Ubiquiti
EdgeRouter-4 (EdgeOS v3.0.1)** — not a container. Chosen over a self-hosted mesh
(NetBird) for simplicity: runs on hardware we already own, no extra services to
maintain, excellent mobile support. 4 peers (paul / jake / user2 / user4).

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
- **Server public key** `<PUBKEY>`

## Peers
| Name | Tunnel IP | Public key |
|------|-----------|-----------|
| paul  | 10.10.10.4 | `<PUBKEY>` |
| jake  | 10.10.10.2 | `<PUBKEY>` |
| user2 | 10.10.10.3 | `<PUBKEY>` |
| user4 | 10.10.10.5 | `<PUBKEY>` |

**Client configs (which contain the private keys) live on jarvis at
`/opt/homelab/wireguard-clients/{name}.conf` + `{name}.png` (QR), perms 600 — NOT in
git.** Each person imports by scanning their QR with the WireGuard mobile app (or
loading the `.conf`). Distribute securely.

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
- **Add:** `wg genkey | tee priv | wg pubkey` → `set interfaces wireguard wg0 peer
  <PUB> allowed-ips 10.10.10.N/32` (+ `description`), commit; build the client `.conf`
  (copy an existing one, swap PrivateKey/Address) + `qrencode -t png`.
- **Remove:** `delete interfaces wireguard wg0 peer <PUB>`, commit; delete the
  client's files in `/opt/homelab/wireguard-clients/`.
