# Workstation Agent Practice

This context names workstation-owned agent support concepts.

## Language

**Workstation configuration freshness**:
Owned by `workstation-setup`; canonical definition lives in homelab-iac's `CONTEXT.md`.
_Avoid_: Home Manager generation check, local freshness algorithm

**Workstation-local Moraine**:
The v1 Moraine deployment whose ingestion, persistence, and query backend all
run under the workstation user without depending on Overmind.
_Avoid_: Shared Moraine, Overmind Moraine

**Moraine central server**:
Moraine's per-user local Unix-socket backend within Workstation-local Moraine.
_Avoid_: Remote backend, central database

**Workstation applicability**:
The chezmoi `is_workstation` data value, true only on the host named
`workstation`. It expresses host identity, not container membership: another
LXC guest is not a workstation and gets none of the workstation treatment.
_Avoid_: is_lxc, LXC applicability, container flag

**Accepted exposure**:
The facts this public repository deliberately discloses — the git identity, the
`/home/faviann` path, the Proxmox/LXC topology, and the `admin.faviann.com`,
`public.faviann.com`, and `ai.faviann.com` endpoints — as distinct from a
leak. Enumerated in [ADR 0001](docs/adr/0001-public-repo-accepted-exposure.md).
_Avoid_: Leak, disclosure risk, sensitive data
