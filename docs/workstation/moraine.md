# Workstation Moraine

## Pinned release

The workstation profile installs the official upstream Moraine v0.7.8 release
bundle for `x86_64-unknown-linux-gnu`, pinned by its SHA-256 hash in
`packages/moraine.nix`. It installs the CLI, ingest, monitor-compatibility
alias, and MCP executables, plus the monitor assets from the same bundle.
There is intentionally no separate monitor unit; the unified MCP/backend
executable owns the monitor HTTP listener, native loopback `/mcp` endpoint, and
private MCP socket. `moraine --version` reports the release version with
upstream's build commit, such as `0.7.8+gfbaa99c95345`.

To upgrade, change the version and hash in `packages/moraine.nix` together,
and compare the new release's notes and `moraine <command> --help` output with
the invocations in `scripts/moraine-service` and `home/workstation.nix`. Since
v0.7.4, `--output` belongs to each command, so the health check runs
`moraine status --output json`.

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
the pinned release serves `POST /mcp`, and its per-user MCP Unix socket at mode
0600; there is no non-loopback listener. Applying a Home Manager generation
restarts the service when the managed Moraine configuration changes, so
ingestion reloads newly declared sources.

For this pinned release, HTTP MCP requires an explicit loopback IP in
`backend.bind`: wildcards, non-loopback addresses, and `localhost` do not enable
`/mcp`, even with an `auth_token`. HTTP uses the default backend; named-backend
routing and `--project-only` retrieval remain stdio-only because HTTP has no
launch-directory context.

## Codex integration

Home Manager does not manage `~/.codex/config.toml`. Chezmoi sets only the
`artifact_server` MCP server in it, as in
[BOOTSTRAP.md](../../BOOTSTRAP.md#bitwarden-artifact-server-api-key-item), and
the [agent defaults](toolchain.md#agent-defaults). It registers no Moraine
server. Moraine's local producer and query backend operate
without a Codex MCP registration; that integration can be added later if the
workstation needs Codex to query Moraine directly.
