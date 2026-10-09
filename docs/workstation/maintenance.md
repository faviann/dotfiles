# Workstation maintenance

Run `workstation-update` for routine maintenance. It validates the chezmoi
source as a clean, canonical `main` checkout, fetches `origin/main`, and
delegates the fast-forward to Git. It then previews, applies, and verifies
chezmoi targets, calls `workstation-setup`, and refreshes the agent tools.
Every invocation runs these reconciliation steps, including when the source
commit is unchanged. This makes failed maintenance retryable without an
applied-commit cache.

`workstation-setup`, installed by Ansible, owns workstation configuration
freshness and decides whether the Home Manager build needs activation.

## Ownership boundaries

Git owns index, worktree, and ref updates through
[`merge --ff-only --no-autostash --no-overwrite-ignore`](https://git-scm.com/docs/git-merge).
Chezmoi owns target reconciliation and
[conflict prompts](https://www.chezmoi.io/reference/commands/apply/).
The wrapper forces neither source convergence nor target overwrites. Run it
with exclusive use of the source checkout; its lock serializes maintenance
commands, not arbitrary concurrent Git commands or editors.

`workstation-update` never rewrites `flake.lock`. .NET release discovery and
publication happen through the dedicated GitHub workflow; maintenance delivers
that validated commit through the same path as other workstation changes.

## Source guards

The command requires a clean canonical `main` checkout tracking `origin/main`.
Local content, a different origin or upstream, and ahead or diverged history
stop the update for manual resolution.

## Secrets

With Bitwarden locked, press Enter to keep existing secret-backed files. A valid
`BW_SESSION` refreshes them automatically. Run `workstation-update --help` for
explicit skip and refresh options.

Missing, empty, or unreadable secret-backed files require unlocking; the command
lists them before prompting. Unattended runs keep existing files when locked,
but require an exported `BW_SESSION` when files need restoring.

Skipping preserves **entire files**, including workstation `.gitconfig`, and
excludes them from verification. Their nonsecret changes are deferred too.
Use `--refresh-secrets` after rotation or credential failures: file presence
alone cannot establish validity.

Each phase announces its work and reports elapsed seconds when it finishes.
The final line reports total time; a failed phase reports its elapsed time and
the total so far. Timings include time spent answering prompts. Use them to identify
the slow phase before investigating its commands.

Completion reports deferred secret refreshes; preview output omits file contents
to keep credentials out of terminal logs.
Chezmoi lifecycle scripts must succeed during apply; verification checks files
without rerunning those scripts.

## Failure recovery

The agent-tool phase checks npm package compatibility before replacing any
executable, then confirms that each Bun-run harness starts. There is no
automatic rollback. On failure, use the command's diagnostics to correct the
problem, then rerun `workstation-update`. Success is reported only after these
checks pass; no separate status cache needs repairing.

## update-agent-tools

The lower-level `update-agent-tools` command remains available for targeted
recovery when a dotfiles/source or workstation-configuration failure prevents
`workstation-update` from reaching its agent-tool phase. Use it only to repair
that agent-tool state, then return to `workstation-update` for routine
maintenance.

Home Manager also uses `update-agent-tools` during bootstrap when managed
commands are missing.

## Login and maintenance ownership

Login only loads the shell PATH, Nix environment, and Home Manager session
variables. It performs no network checks or updates, does not source `.bashrc`,
and does not launch tmux. Package managers resolve releases during
explicit maintenance, chezmoi tracks target state, and `workstation-setup`
checks configuration freshness. Only maintenance lock files are active under
`~/.local/state/workstation-update` and `~/.local/state/update-agent-tools`;
there is no freshness cache or workstation-side update scheduler.

An explicit maintenance run may replace agent tools under running sessions and
restart changed user services, so choose an appropriate maintenance window.
