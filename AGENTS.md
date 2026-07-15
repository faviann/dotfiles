## Agent skills

### Issue tracker

Issues and PRDs are tracked in GitHub Issues; external PRs are not a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

The canonical triage-label vocabulary is used without overrides. See `docs/agents/triage-labels.md`.

### Domain docs

This repository uses a single-context layout. See `docs/agents/domain.md`.

### Validation

List behavioral suites and cases with `bash scripts/run-tests --list`. During
iteration, run one exact case or one exact suite:

```bash
bash scripts/run-tests --case test_exact_case_name
bash scripts/run-tests --suite workstation-update.bash
```

For Bash or shell-template work, run focused analysis with
`nix run .#shellcheck`.

The sole full closeout command is `nix flake check`. It runs focused shell
analysis, the test-runner contract, and every behavioral suite in the declared
Nix environment; do not run a redundant standalone full behavioral pass
immediately beforehand.
