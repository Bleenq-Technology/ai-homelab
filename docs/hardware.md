# jarvis — hardware

The physical spec of the homelab host **`jarvis`** (`192.168.2.10`). Deliberately **modest,
affordable, second-hand-friendly** consumer hardware — a single AM4 desktop with a used RTX 3090,
not a datacenter node. It sets the capacity/VRAM envelope every service budgets against; "homelab"
in the literal sense.

> Last inventoried **2026-06-25** (read from the host's SMBIOS/`lsblk`/`nvidia-smi`). Re-check with
> the commands in [§Re-inventory](#re-inventory).

## At a glance
| Component | Spec |
|---|---|
| **Motherboard** | ASUS **ROG STRIX B450-F GAMING** (Rev 1.xx), AMD **B450** chipset, Socket **AM4** |
| **BIOS** | AMI **4602** (2021-08-17) |
| **CPU** | AMD **Ryzen 5 3600X** — Zen 2, **6 cores / 12 threads**, ~3.8 GHz base / **4.4 GHz** boost, 32 MiB L3, 95 W |
| **Memory** | **64 GB** (2 × 32 GB) **DDR4-3200**, dual-rank, non-ECC · **2 of 4 slots free → 128 GB max** |
| **GPU** | NVIDIA **GeForce RTX 3090** (GA102), **24 GB** GDDR6X · driver 595.71.05 · PCIe 3.0 ×16 |
| **Boot/OS drive** | Samsung **990 PRO 1 TB** NVMe (PCIe Gen4 drive, Gen3 link on B450) → `/` |
| **Bulk/data drive** | Samsung **870 EVO 2 TB** SATA SSD → `/srv/ai-data` |
| **Network** | Intel **I211** Gigabit Ethernet (`enp3s0`) |
| **OS** | **Ubuntu 26.04 LTS**, kernel 7.0.x |
| **Swap** | 8 GB (`/srv/ai-data/swap.img`) |

## Memory — current modules & the upgrade path
**This is the one to get right when buying more — match the existing part.**

- **Installed:** 2 × 32 GB = **64 GB**, in slots **DIMM_A2** and **DIMM_B2** (A1/B1 empty).
- **Exact part:** Micron / Crucial Pro **`CP32G4DFRA32A.C16FF`** — 32 GB **DDR4-3200** (PC4-25600),
  **dual-rank**, 288-pin **UDIMM**, non-ECC, 1.2 V. Both modules run at the full **3200 MT/s** today.
- **Board limit:** **128 GB** across **4** DIMM slots (non-ECC). So the upgrade is **+2 × 32 GB** into
  the open **A1/B1** slots → **128 GB**.

**Upgrade guidance (when DDR4 pricing cooperates):**
- **Buy the identical part** (`CP32G4DFRA32A.C16FF`, or the same-spec Crucial Pro 32 GB DDR4-3200
  dual-rank UDIMM). Matching modules maximizes the chance of clean 4-DIMM training.
- **Expect the clock to drop.** Four **dual-rank** DDR4 DIMMs on a **B450 + Zen 2** memory controller
  rarely sustain 3200 MT/s — it typically trains down to ~**2933 / 2667 MT/s**. For this host, where
  RAM **capacity** is the constraint (LLM/Chromium/data services), not bandwidth, that's an acceptable
  trade. Manual timings can claw some back at the cost of stability tuning.
- Cross-check the **ASUS B450-F GAMING memory QVL** for a validated 4 × 32 GB / 128 GB entry; a BIOS
  update past 4602 can improve 4-DIMM training (not required).
- **No ECC** — this platform (B450 + non-Pro Ryzen) doesn't do reliable ECC; these are non-ECC UDIMMs.

The 128 GB headroom is what de-risks the heavier RAM consumers on the backlog (e.g. Firecrawl's
Chromium workers — `todos.md` #18).

## CPU
AMD **Ryzen 5 3600X** (Matisse / Zen 2, AM4): 6C/12T, boost to ~4.41 GHz, 32 MiB L3, PCIe 3.0 platform.
Modest but ample for orchestrating containers — the heavy lifting is on the GPU.

## GPU
NVIDIA **GeForce RTX 3090** (GA102, **24 GB GDDR6X**) — a **used** card, the lab's compute workhorse.
At PCI `09:00.0`, driver **595.71.05**, VBIOS `94.02.42.00.F1`. Negotiates **PCIe 3.0 ×16** (the card is
Gen4-capable; B450 is a Gen3 platform). The 24 GB VRAM is a **shared budget** across the host LLM
(unsloth), ComfyUI, and bge-m3 — see [host/unsloth/README.md](../host/unsloth/README.md) and
[docker/ai/comfyui](../docker/ai/comfyui/) for the VRAM-budget rationale (ComfyUI runs
`--disable-smart-memory` to free its ~6.5 GB when idle).

## Storage
Two SSDs, tiered on purpose — hot/latency-sensitive on the fast NVMe, bulk/heavy-write on the big SATA
SSD. Full rationale + the migration plan: [docs/storage-tiering-plan.md](storage-tiering-plan.md).

| Drive | Model (serial) | Bus | Layout |
|---|---|---|---|
| **NVMe** | Samsung **990 PRO 1 TB** (`S7LANL0L101197T`) | PCIe NVMe | `p1` 1 G EFI `/boot/efi` · `p2` 2 G `/boot` · `p3` 928 G **LVM** (`ubuntu-vg/ubuntu-lv`) ext4 **`/`** |
| **SATA** | Samsung **870 EVO 2 TB** (`S6PNNM0TA21899N`) | SATA | `sda1` ext4 **`/srv/ai-data`** (by-UUID, `nofail`) |

- **`/`** (NVMe): 913 G, ~21 % used. OS, `/var/lib/docker`, hot DBs (Postgres, Redis, Qdrant).
- **`/srv/ai-data`** (SATA): 1.8 T, ~2 % used. The heavy-write / bulk tier — **QuestDB** (market-data,
  `marketdata/questdb`), **MinIO** (`object-store`), **ClickHouse** (`telemetry/clickhouse`), and the
  **Redpanda** event-spine log (`streaming/redpanda`), all relocated here 2026-06-28 (backups + model
  caches still pending — see the tiering plan). The NVMe sits in the 3090's airflow path, so moving
  sustained **writes** here is a write-wear + thermal win (see the tiering plan).
- The 990 PRO is high-endurance (~600 TBW); the 870 EVO ~1200 TBW.

## Network
Single **Intel I211 Gigabit** NIC (`enp3s0`) on the LAN at **192.168.2.10**. Docker/libvirt bridges
(`docker0`, `br-*`, `virbr0`) are virtual. Internal name resolution (`*.lab.example`) is served
off the EdgeRouter; see [docker/README.md](../docker/README.md).

## Re-inventory
All read-only; jarvis has passwordless sudo for the `homelab` group:
```bash
sudo dmidecode -t baseboard -t bios   # board model + BIOS version
lscpu                                 # CPU model / cores / threads / clocks
sudo dmidecode -t 16                  # memory: max capacity + slot count
sudo dmidecode -t 17                  # memory: per-DIMM size/speed/part number/which slots are empty
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN ; lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT   # drives + layout
```
