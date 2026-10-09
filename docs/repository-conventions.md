# Repository conventions

## Repository-only files

[`.chezmoiignore`](../.chezmoiignore) excludes repository documentation, tests,
scripts, `flake.nix`, `flake.lock`, `home/`, and `packages/` from chezmoi's
home-directory targets. Match target paths, not encoded source names (for
example, `.config/fish`, not `dot_config/fish`). Excluding an entire subtree requires
both its directory and contents patterns, such as `docs/` and `docs/**`.

Git and chezmoi exclusions are independent: `.chezmoiignore` does not prevent
publication, and Git ignore rules do not prevent chezmoi applying a source path.
Keep private or machine-local notes outside the canonical source checkout;
[workstation maintenance](workstation/maintenance.md) rejects local content,
including ignored files.

## Machine profiles

`.chezmoiignore` is the only place that decides which
[machine profile](../CONTEXT.md) gets which target, scripts in
`.chezmoiscripts/` included. Gate a target there on `.profile`; do not turn its
source into a template to gate it. The table in
[`tests/chezmoi-target-inventory.bats`](../tests/chezmoi-target-inventory.bats)
lists every managed target with its profiles, and the suite fails when a
profile's managed inventory differs from it. Add a new target to that table
with the profiles that get it.

After changing the target inventory, inspect it before applying:

```bash
chezmoi -S "$PWD" ignored --tree
chezmoi -S "$PWD" managed --path-style=source-relative --tree
```

Add `--override-data '{"profile":"desktop"}'` to inspect another profile.

## Validation

Behavioral tests use [Bats](https://bats-core.readthedocs.io/). Discover suites
and cases, then run one case or suite in the Nix development environment:

```bash
rg '^@test ' tests
nix develop -c bats --filter '^test_exact_case_name$' tests
nix develop -c bats tests/workstation-update.bats
```

Run focused shell analysis after changing Bash or shell templates:

```bash
nix run .#shellcheck
```

Use the complete flake validation as the sole full closeout gate:

```bash
nix flake check
```

It includes ShellCheck and every Bats suite in the declared Nix environment,
so a standalone full behavioral run immediately beforehand is redundant.
