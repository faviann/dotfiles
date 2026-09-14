# Workstation Moraine

## Pinned build

The workstation profile source-builds Moraine at commit `91cd7a13ba29`, the
mainline merge of upstream PR #658 after v0.7.3, with the upstream Rust 1.96.0
toolchain and locked Cargo closure. It installs matching CLI, ingest,
monitor-compatibility alias, and MCP executables, while reusing the unchanged,
hash-pinned v0.7.3 monitor assets. There is intentionally no separate monitor
unit; the unified MCP/backend executable owns the monitor HTTP listener, native
loopback `/mcp` endpoint, and private MCP socket. The source still reports
version 0.7.3, so use the commit-bearing `moraine --version` output, not the
semantic version alone, to identify this build.

## Memory headroom

The package temporarily gives Moraine's interactive query profile 8 GiB, its
ClickHouse user a 16 GiB aggregate limit, and managed ClickHouse a 48 GiB
process limit on this 64 GiB host. This keeps session discovery usable while
upstream issue #599's bounded summary query remains unresolved. Background
queries retain upstream's 256 MiB ceiling. Remove
`packages/moraine-managed-memory-headroom.patch` when a bounded upstream
discovery path is pinned. Managed ClickHouse refuses startup below 2 GiB of
detected memory; `moraine up` may restart it when managed resource settings
change.

## Configuration and state

Home Manager owns `~/.moraine/config.toml` as a read-only Nix-managed file.
Persistent ingestion state, ClickHouse data, logs, sockets, and process state
remain under `~/.moraine`. Do not use `moraine setup` or another config-writing
command to mutate the managed file; change this module and apply a new Home
Manager generation instead.

The enabled sources backfill and watch active Codex sessions recursively,
archived sessions in Codex's flat archive directory, and standard Claude Code
project transcripts under `~/.claude/projects`. The deployment-owned Claude
source is named `claude-projects`, avoiding upstream setup migrations that
append unrelated default harnesses. Claude job timelines under `~/.claude/jobs`
are intentionally excluded. Moraine's default built-in redaction runs before
local storage.

## Service and topology

The single `moraine.service` user unit is the operator surface for the local
stack. Upstream `moraine up` owns managed ClickHouse readiness, database
migrations, ingest, and unified-backend startup. The foreground unit monitors
aggregate Moraine health and restarts the complete stack on failure. Default
Moraine topology explicitly keeps the HTTP listener on `127.0.0.1:8080`, where
the pinned build serves `POST /mcp`, and its per-user MCP Unix socket at mode
0600; there is no non-loopback listener. Applying a Home Manager generation
restarts the service when the managed Moraine configuration changes, so
ingestion reloads newly declared sources.

For this pinned build, HTTP MCP requires an explicit loopback IP in
`backend.bind`: wildcards, non-loopback addresses, and `localhost` do not enable
`/mcp`, even with an `auth_token`. HTTP uses the default backend; named-backend
routing and `--project-only` retrieval remain stdio-only because HTTP has no
launch-directory context.

## Codex integration

The workstation profile does not manage `~/.codex/config.toml` or register a
Codex MCP server. Moraine's local producer and query backend operate without a
Codex MCP registration; that integration can be added later if the workstation
needs Codex to query Moraine directly.
