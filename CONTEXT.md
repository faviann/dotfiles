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

**Machine profile**:
The chezmoi `profile` data value that selects which targets a machine gets:
`workstation` for the LXC host of that name, `desktop` for every other host.
It expresses host identity, not container membership.
Distinct from the Home Manager profiles, `workstation` and `desktop`, which
share the machine profiles' names. A desktop machine applies its own Home
Manager profile from `chezmoi apply`; the workstation applies its profile
through `workstation-setup`.
_Avoid_: is_workstation, is_lxc, container flag

**Accepted exposure**:
The facts this public repository deliberately discloses — the git identity, the
`/home/faviann` path, the Proxmox/LXC topology, and the `admin.faviann.com`,
`public.faviann.com`, and `ai.faviann.com` endpoints, and the homelab LAN
addresses and historical hostnames in git history — as distinct from a leak.
Enumerated in [ADR 0001](docs/adr/0001-public-repo-accepted-exposure.md).
_Avoid_: Leak, disclosure risk, sensitive data
