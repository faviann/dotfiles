# Workstation dev sessions

`dev-session` provisions and removes the coding-worker environment for one
GitHub issue. An orchestrator calls it, then talks to the worker directly
through [Herdr](herdr.md); `dev-session` never sends a work prompt, interprets
work, reviews code, or decides completion.

```bash
dev-session ensure <project> <issue>
dev-session remove <project> <issue>
```

## Identity

Identity is the `<project, issue>` pair, and every resource is derived from it:
the repository `~/repos/<project>`, the branch `issue-<issue>`, the worktree
`~/worktrees/<project>/issue-<issue>`, a Herdr workspace labelled
`<project>/issue-<issue>`, and the Codex worker running in that worktree.

The worker's Herdr launch name is a readable label carrying a digest of the
pair, so distinct identities never compete for one name; it is never used to
identify a worker. Git and Herdr are the only sources of truth; no session
database, pane-ID tracking, or background supervision is kept. The command
resolves its own PATH, so it runs unchanged over [Lobu](lobu.md) and other
non-interactive transports.

## ensure

`ensure` reuses whatever already matches and creates only what is missing. A
new issue branch starts from the repository's default branch; an existing one is
reused without reset or rebase, and a dirty worktree is valid. The worker is
discovered by the expected worktree's working directory, so a working or blocked
worker is reused and never interrupted.

A missing or dead worker is replaced with a fresh Codex worker launched as
`-m gpt-5.6-luna -c 'model_reasoning_effort="xhigh"'`, keeping the
workstation's own Codex approval and sandbox settings. A generated worktree is a
project Codex has never seen, so the launch also trusts that one path through an
invocation-scoped `-c` override; nothing is written to `~/.codex/config.toml`.
Without it Codex stops at its folder-trust prompt, which Herdr reports as `idle`
rather than `blocked`. Before launching, the pending input line of the target
pane is discarded: Codex leaves its terminal keyboard report as pending shell
input when it exits, and that fragment would otherwise corrupt the next launch
command.

Contradictory state — the issue branch checked out elsewhere, a foreign checkout
at the expected path, or more than one worker or workspace matching the session
— is reported instead of repaired. `ensure` prints JSON naming the repository,
issue, branch, worktree, current Herdr target, and observed worker state.
Success means the worker exists and Herdr can address it, not that it is idle.

## remove

`remove` deletes only the session's own worker panes, its workspace, and its
worktree. The matching worker goes wherever its pane currently lives, since
location is not part of its identity. It refuses to interrupt a working worker
or to remove a dirty worktree, proceeds when worker activity cannot be
determined, leaves unrelated workspace contents alone, and tolerates resources a
partial cleanup already removed. The local branch, its remote counterpart, and
the pull request all survive. There is no force cleanup: resolve a refusal by
hand.

Missing repositories are never cloned.
