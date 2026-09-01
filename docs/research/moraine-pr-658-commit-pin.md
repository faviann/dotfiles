# Moraine PR #658 commit-pin assessment

Date: 2026-09-01

## Recommendation

Pin Moraine commit
[`91cd7a13ba29cbaca8b1fbc2855864d3e87e54b9`](https://github.com/eric-tramel/moraine/commit/91cd7a13ba29cbaca8b1fbc2855864d3e87e54b9)
and continue the existing #225 architecture. Do not add a transport bridge.

This is the canonical commit on upstream `main` created when
[PR #658](https://github.com/eric-tramel/moraine/pull/658) was squash-merged. It
is the smallest mainline boundary containing the reviewed native HTTP MCP
endpoint. Its tree is identical to the PR's final head, while later `main`
contains unrelated changes, including migration 035. Pinning this full commit
therefore gets the required endpoint without silently adopting arbitrary
post-#658 behavior.

Waiting for a release is defensible only if maintaining a source build is not
acceptable. It is not technically necessary: the endpoint is merged, its five
checks passed, and upstream's stack validation exercised concurrent HTTP MCP
clients. The latest published release remains
[v0.7.3](https://github.com/eric-tramel/moraine/releases/tag/v0.7.3), so there is
no official binary asset for the recommended commit.

## 1. Can this workstation cleanly pin and install the commit?

Yes, as a source-built Nix package. It should remain under the existing Home
Manager ownership rather than using upstream `make install`, which would put a
mutable development install outside the Nix profile.

The current package is a fixed-output download of the v0.7.3 Linux release
bundle ([`packages/moraine.nix`](../../packages/moraine.nix)). A clean commit
pin requires replacing that binary-only fetch with a source derivation that:

1. fetches `eric-tramel/moraine` at the full `91cd7a1...` revision with a fixed
   source hash;
2. uses the upstream-pinned Rust 1.96.0 toolchain and the checked-in
   `Cargo.lock` ([toolchain](https://github.com/eric-tramel/moraine/blob/91cd7a13ba29cbaca8b1fbc2855864d3e87e54b9/rust-toolchain.toml),
   [lockfile](https://github.com/eric-tramel/moraine/blob/91cd7a13ba29cbaca8b1fbc2855864d3e87e54b9/Cargo.lock));
3. builds the four release binaries `moraine`, `moraine-ingest`,
   `moraine-monitor`, and `moraine-mcp`, matching upstream's
   [release packaging script](https://github.com/eric-tramel/moraine/blob/91cd7a13ba29cbaca8b1fbc2855864d3e87e54b9/scripts/package-moraine-release.sh);
4. sets `MORAINE_BUILD_GIT_SHA=91cd7a13ba29` so `moraine --version` proves
   which post-release source was built; upstream's
   [build script](https://github.com/eric-tramel/moraine/blob/91cd7a13ba29cbaca8b1fbc2855864d3e87e54b9/crates/moraine-config/build.rs)
   supports that explicit build identity; and
5. preserves the current bundle layout, including `web/monitor/dist`, so the
   existing `runtime.service_bin_dir` and static-asset discovery continue to
   work.

There is one packaging wrinkle, but not an architectural blocker. The locked
nixpkgs currently exposes Rust 1.94.1, while this Moraine tree pins 1.96.0, so
the flake must add a fixed Rust 1.96.0 toolchain source. The frontend also uses
Bun. No monitor frontend files changed between v0.7.3 and `91cd7a1`, so the
lowest-risk package can reuse the already hash-pinned v0.7.3 monitor assets
while compiling the four binaries from the pinned source. Alternatively, the
Nix package can vendor the locked Bun dependency closure and rebuild those
identical assets. Either route remains reproducible; the former is the smaller
change.

The existing Home Manager design already threads one `morainePackage` through
`home.packages`, `runtime.service_bin_dir`, `ExecStart`, and `ExecStop`
([`home/workstation.nix`](../../home/workstation.nix)). Changing that one
package keeps all four binaries on one commit and causes the generated user
unit to use the new store path.

## 2. Why pin `91cd7a1...` rather than current `main`?

The v0.7.3 tag resolves to `196bb71328716e87d858891c3f8071c54eafcd55`.
The mainline commits from that tag through the recommendation are:

| Commit | Upstream change | Relevance |
| --- | --- | --- |
| `8d557b99d695c06964f861facf51f1545fa9ef1c` | [PR #657](https://github.com/eric-tramel/moraine/pull/657), MCP backend health checking | No config or migration change. |
| `d6012e13322088474654084f61db800a0baff1bb` | [PR #654](https://github.com/eric-tramel/moraine/pull/654), bounded ClickHouse resources | Operational compatibility impact described below. |
| `517b6480ff0324c21a3b853e947db1a5fbc7e322` | [PR #653](https://github.com/eric-tramel/moraine/pull/653), adaptive migration memory bounds | Affects execution only if migrations 031 or 033 are pending. |
| `91cd7a13ba29cbaca8b1fbc2855864d3e87e54b9` | [PR #658](https://github.com/eric-tramel/moraine/pull/658), shared HTTP MCP endpoint | The required feature boundary. |

Later `main` includes unrelated CLI, retrieval, dispatch, and stdio changes and
adds `sql/035_canonical_open_seek.sql`. There is no reason for #225 to absorb
those changes before they are released or separately assessed.

## 3. Moraine configuration and deployment changes

No new Moraine config key is required. PR #658 explicitly states that the
default `127.0.0.1:8080` listener serves
`POST http://127.0.0.1:8080/mcp` and that no configuration key was added.
The pinned
[configuration contract](https://github.com/eric-tramel/moraine/blob/91cd7a13ba29cbaca8b1fbc2855864d3e87e54b9/docs/configuration.md#L954-L980)
and
[bind guard](https://github.com/eric-tramel/moraine/blob/91cd7a13ba29cbaca8b1fbc2855864d3e87e54b9/docs/configuration.md#L1020-L1058)
say:

- `moraine up` starts the unified backend;
- `backend.bind` defaults to `127.0.0.1`;
- `monitor.port` defaults to `8080`; and
- `/mcp` is mounted only when `backend.bind` is an explicit loopback IP.
  Wildcards, non-loopback addresses, and hostnames such as `localhost` do not
  qualify. An `auth_token` does not enable MCP on a non-loopback bind.

This workstation's Nix-managed config omits `[backend]` and `[monitor]`, so its
effective values already are `127.0.0.1` and `8080`. The existing
`moraine.service` already runs `moraine up` through `scripts/moraine-service`.
Therefore the only required deployment change is the package pin and consequent
service restart. Making the two default values explicit in the managed TOML
would improve reviewability and make the loopback security invariant testable,
but is not necessary for the endpoint to exist.

Do not run `moraine setup` against this workstation's config: Home Manager owns
the file. PR #658's setup migration is useful for installations where Moraine
owns Codex/Claude registration; it is not needed to make `/mcp` available, and
sigbit can be pointed at the verified URL later. The HTTP endpoint always uses
the default backend; named-backend routing and `--project-only` retrieval remain
stdio-only because HTTP requests have no launch-directory context
([upstream install documentation](https://github.com/eric-tramel/moraine/blob/91cd7a13ba29cbaca8b1fbc2855864d3e87e54b9/docs/agent-mcp-search/install.md#L181-L200)).

## 4. Migration and compatibility implications

There is no new schema migration. Both v0.7.3 and `91cd7a1` contain migrations
001 through 034; the only SQL-file change is revised migration-031 behavior for
databases where it is still pending. PR #658 itself says, “No schema migration
or new configuration key is required.” This workstation's live capability
response currently reports schema level 034, and `moraine status` reports no
pending migrations, so the #653 adaptive 031/033 path should not run here.

The material compatibility change is intervening PR #654:

- `moraine up` converges an existing managed ClickHouse installation to new
  query memory, concurrency, spill, temporary-disk, and workload limits;
- ClickHouse may restart once when that managed configuration changes;
- managed ClickHouse now refuses startup below 2 GiB of detected memory; and
- overload responses distinguish `busy` from `resource_exhausted`, while the
  default interactive MCP parallelism is lower.

These are documented in [PR #654's operational
impact](https://github.com/eric-tramel/moraine/pull/654). This workstation has
32 GiB RAM, uses the managed ClickHouse `v25.12.5.44-stable`, and is currently
healthy, so it clears the memory prerequisite. Plan for a brief local Moraine
outage during the first upgraded `moraine up`; do not expect a data/schema
migration.

The source tree's Cargo package version is still `0.7.3`. This is why the Nix
package and binary build metadata must retain the commit SHA: a bare semantic
version is insufficient evidence that `/mcp` is present.

## 5. Pre-sigbit local verification

Yes. Verify the package identity, loopback listener, initialize handshake,
initialized notification, and exact tool list before changing sigbit. The
protocol below follows upstream's checked-in
[`mcp_http_smoke.py`](https://github.com/eric-tramel/moraine/blob/91cd7a13ba29cbaca8b1fbc2855864d3e87e54b9/scripts/ci/mcp_http_smoke.py):

```bash
set -euo pipefail

endpoint=http://127.0.0.1:8080/mcp
protocol=2025-06-18
smoke_dir=$(mktemp -d)
trap 'rm -rf "$smoke_dir"' EXIT

moraine --version | grep -F '91cd7a13ba29'

curl --fail-with-body --silent --show-error \
  --output "$smoke_dir/initialize.json" \
  --header 'Content-Type: application/json' \
  --header 'Accept: application/json, text/event-stream' \
  --header 'Origin: http://127.0.0.1' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"sigbit-predeploy-smoke","version":"1"}}}' \
  "$endpoint"

jq -e --arg protocol "$protocol" \
  '.jsonrpc == "2.0" and .id == 1 and .result.protocolVersion == $protocol and (.error | not)' \
  "$smoke_dir/initialize.json"

notification_status=$(
  curl --silent --show-error \
    --output "$smoke_dir/initialized.body" \
    --write-out '%{http_code}' \
    --header 'Content-Type: application/json' \
    --header 'Accept: application/json, text/event-stream' \
    --header 'Origin: http://127.0.0.1' \
    --header 'MCP-Protocol-Version: 2025-06-18' \
    --data '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    "$endpoint"
)
test "$notification_status" = 202
test ! -s "$smoke_dir/initialized.body"

curl --fail-with-body --silent --show-error \
  --output "$smoke_dir/tools-list.json" \
  --header 'Content-Type: application/json' \
  --header 'Accept: application/json, text/event-stream' \
  --header 'Origin: http://127.0.0.1' \
  --header 'MCP-Protocol-Version: 2025-06-18' \
  --data '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  "$endpoint"

jq -e '
  .jsonrpc == "2.0" and .id == 2 and (.error | not) and
  ([.result.tools[].name] == [
    "search_sessions",
    "open",
    "list_sessions",
    "file_attention",
    "get_ingest_status"
  ])
' "$smoke_dir/tools-list.json"
```

Success proves that the upgraded binary, the loopback-only route gate, MCP
protocol negotiation, and the expected retrieval surface all work locally. A
subsequent read-only `tools/call` for `get_ingest_status` or a harmless
`search_sessions` query can add end-to-end ClickHouse evidence, but initialize
plus `tools/list` is sufficient to gate the sigbit transport reconfiguration.

## Decision

Proceed with the post-v0.7.3 commit pin at `91cd7a1...`, preserve the native
loopback endpoint, smoke-test it locally, and then continue #225. Waiting for a
release trades away progress but does not reduce an identified compatibility
risk enough to justify it. A bridge would duplicate merged upstream behavior
and introduce an extra process, protocol translation, lifecycle surface, and
security boundary without need.
