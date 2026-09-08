## Agent skills

### Issue tracker

Issues and PRDs are tracked in GitHub Issues; external PRs are not a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

The canonical triage-label vocabulary is used without overrides. See `docs/agents/triage-labels.md`.

### Domain docs

This repository uses a single-context layout. See `docs/agents/domain.md`.

### Validation

Behavioral tests use Bats. Discover suites and cases with
`rg '^@test ' tests`. During iteration, run one exact case or one suite in
the declared development environment:

```bash
nix develop -c bats --filter '^test_exact_case_name$' tests
nix develop -c bats tests/workstation-update.bats
```

For Bash or shell-template work, run focused analysis with
`nix run .#shellcheck`.

The sole full closeout command is `nix flake check`. It runs focused shell
analysis and every behavioral suite in the declared Nix environment; do not
run a redundant standalone full behavioral pass immediately beforehand.
