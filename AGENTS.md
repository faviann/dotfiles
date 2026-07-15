## Agent skills

### Issue tracker

Issues and PRDs are tracked in GitHub Issues; external PRs are not a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

The canonical triage-label vocabulary is used without overrides. See `docs/agents/triage-labels.md`.

### Domain docs

This repository uses a single-context layout. See `docs/agents/domain.md`.

### Validation

For Bash or shell-template work, run `nix run .#shellcheck`. Before closeout,
run the full `nix flake check`.
