# Detached execution and observability for one Sandcastle run

Researched 2026-07-16 against Sandcastle v0.12.0, tmux, systemd, GNU
Coreutils, Agent of Empires, and this repository's workstation configuration.
Sandcastle and Agent of Empires source links are pinned to commits
[`e99f832f26dc9d245c019a9ddd19fa5dee792427`](https://github.com/mattpocock/sandcastle/tree/e99f832f26dc9d245c019a9ddd19fa5dee792427)
and
[`c2e972fb525900b8802b884cafb34ff8d0b0bab3`](https://github.com/agent-of-empires/agent-of-empires/tree/c2e972fb525900b8802b884cafb34ff8d0b0bab3).

## Recommendation

For the first disposable pilot, run Sandcastle in a **dedicated, named tmux
window inside the existing `main` session** and keep Sandcastle's timestamped
file logging enabled. This is the
smallest option that survives terminal closure, SSH disconnection, and client
loss while retaining both live reattachment and Sandcastle's own durable logs.
It reuses a tool and operating model already present on the workstation, adds no
daemon or committed unit, and does not pretend that the Sandcastle process can
resume after it dies.

Use a window separate from the AoE dashboard window, with a name that identifies
the repository and run. Enable tmux's `remain-on-exit` for failed panes so an
early launcher error remains inspectable. The operational contract should be:

```bash
tmux new-window -d \
  -t main \
  -n sandcastle-<repo>-<run> \
  -c /absolute/path/to/repo \
  '<repo-owned-sandcastle-launcher>'
tmux set-window-option \
  -t main:sandcastle-<repo>-<run> \
  remain-on-exit failed
```

Then use `tmux select-window -t main:sandcastle-<repo>-<run>` from the existing
client (or attach `main` first) for the live terminal. Use
`tmux capture-pane -p -S - -t main:sandcastle-<repo>-<run>` for retained pane
text and `.sandcastle/logs/` as the authoritative run log. The exact launcher
is a separate packaging decision; it should be an executable with a stable
absolute path or a repository-relative command whose dependencies are already
restored.

If the pilot shows that operators prefer noninteractive status and journal
queries over reattachment, the smallest next step is **`systemd-run --user` as a
named transient service**, not a committed Home Manager unit. It provides a
service-manager-owned process, queryable exit state, and journal output without
creating a permanent service. Do not enable automatic restart: Sandcastle has no
durable run state machine, so blindly rerunning the same workflow can repeat
side effects rather than resume the interrupted process.

## Required lifecycle

Sandcastle invokes the generated TypeScript workflow as a foreground host
process. Its Codex provider runs `codex exec --json` inside the selected sandbox,
while `run()` writes timestamped logs under `.sandcastle/logs/` by default and
can additionally stream typed/raw events. On `SIGINT` or `SIGTERM`, Sandcastle
tears down registered sandboxes and exits; captured Codex sessions support a
later *conversation* resume but do not checkpoint or reattach the Sandcastle
process itself.
[Sandcastle logging](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#logging),
[shutdown registry](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/shutdownRegistry.ts),
[resume contract](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#session-capture-resume-and-fork)

Consequently, the wrapper must keep the original foreground process alive when
the client disappears and make its output and termination visible. Host reboot
recovery is expressly unnecessary, so persistent boot activation and automatic
restart solve a larger problem than this ticket asks for.

## Options compared

| Option | Disconnect survival | Status and logs | Recovery and failure semantics | Fit and cost |
| --- | --- | --- | --- | --- |
| Dedicated tmux window | Native fit. A window belongs to the persistent `main` session, which survives accidental SSH disconnects and intentional detach and can be reattached explicitly with `tmux attach -t main`. | Best live inspection: select the exact PTY window; `capture-pane` retrieves retained history. Pane history is bounded and terminal-shaped, so Sandcastle's file logs remain authoritative. `remain-on-exit failed` can preserve a dead pane after launcher failure. | Keeps the original Sandcastle process alive; it does not restart or resume one that exits. Operator cleanup is an explicit `kill-window`. | **Recommended pilot default.** tmux and `main` are already installed and operational. One named window is the smallest added lifecycle surface; a separate named session remains available if later experience shows the run should not share `main`'s lifetime. |
| Named transient `systemd-run --user` service | A transient service starts in a clean, detached environment with the user service manager as parent, independent of the SSH shell. Existing lingering keeps that user manager around after logout. | `systemctl --user status/show <name>.service` exposes process/unit state; stdout/stderr default to the journal and are queryable with `journalctl --user-unit <name>.service`. `--remain-after-exit` can retain runtime information until explicit stop. | Strongest noninteractive exit accounting. Use `Type=exec` so successful submission means the executable was actually invoked. Do not set `Restart=` for the pilot. The clean manager environment requires an explicit working directory and controlled `PATH`; pass only required environment rather than copying the whole login environment. | **Best second option** if journal/status queries matter more than reattachment. One launch command and no committed unit, but more launch parameters and no live PTY unless `--pty` is used—which makes `systemd-run` wait and weakens the detached shape. |
| Permanent Home Manager user service | Same disconnect survival, and it can be enabled at user-manager startup. | Same systemd status/journal facilities; configuration is declarative and reviewable. | Restart and boot policies can be encoded, but a one-shot issue workflow is not a stable daemon and has no safe automatic-resume contract. A templated service would also need an instance-to-repository/run mapping and cleanup policy. | **Defer.** The repo already declares long-running AoE services this way, but a permanent unit is unnecessary for one run and host-reboot recovery is out of scope. Reconsider only after repeated pilots establish a reusable launch contract. |
| Agent of Empires session | AoE sessions already run inside tmux and outlive the TUI/SSH client. | Excellent agent-aware UI for supported interactive agents, with tmux terminal access and status detection; it also supports custom launch overrides. | Sandcastle is an orchestrator that launches Codex, not an interactive Codex CLI session. AoE would see the outer command and cannot derive Sandcastle iteration, branch, or completion semantics from its supported-agent hooks/ACP stream. Removal also adds AoE-owned session/worktree lifecycle around Sandcastle's own lifecycle. | **Do not use as the process owner.** Keep AoE as the workstation dashboard and use ordinary tmux beside it. Integrating Sandcastle as an AoE custom agent would be additional product integration, not the smallest detached runner. |
| `nohup ... &` with file redirection | GNU `nohup` ignores SIGHUP and redirects terminal input/output so a background command can continue after logout. | Only the chosen output file plus ad hoc `ps`/PID tracking; there is no owner that retains trustworthy exit state, start metadata, or a reattachable terminal. | No restart, grouping, structured status, or reliable cleanup contract. A recorded PID can become stale, and wrapper/child process relationships must be managed manually. | **Reject.** It is fewer characters than tmux or systemd but fails the useful-status and recovery-information part of the question. |

tmux's persistence, reattachment, capture, and `remain-on-exit` behavior are part
of its own manual.
[tmux 3.5a manual source](https://github.com/tmux/tmux/blob/3.5a/tmux.1)

`systemd-run` documents the distinction between detached transient services and
caller-environment scopes, recommends `Type=exec` for reliable invocation, and
provides working-directory, environment, PTY, and remain-after-exit controls.
Service stdout defaults to the journal, while lingering starts a user manager at
boot and retains it after logout.
[systemd-run](https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html),
[systemd.exec](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#StandardOutput=),
[journalctl](https://www.freedesktop.org/software/systemd/man/latest/journalctl.html),
[loginctl lingering](https://www.freedesktop.org/software/systemd/man/latest/loginctl.html#enable-linger%20USER%E2%80%A6)

AoE explicitly describes each agent as running in its own tmux session and
attributes disconnect survival to tmux. Its custom-agent path requires agent
definitions, launch commands, and status detection; its tool sessions likewise
wrap commands in tmux and tie their cleanup to an AoE agent session.
[AoE operating model](https://github.com/agent-of-empires/agent-of-empires/blob/c2e972fb525900b8802b884cafb34ff8d0b0bab3/README.md#how-it-works),
[adding an agent](https://github.com/agent-of-empires/agent-of-empires/blob/c2e972fb525900b8802b884cafb34ff8d0b0bab3/docs/development/adding-agents.md),
[tool-session lifecycle](https://github.com/agent-of-empires/agent-of-empires/blob/c2e972fb525900b8802b884cafb34ff8d0b0bab3/docs/guides/tool-sessions.md#lifecycle-and-cleanup)

GNU documents `nohup` as SIGHUP immunity plus standard-stream redirection, and
also states that it does not put the command in the background automatically.
It supplies none of the session/service ownership features above.
[GNU Coreutils `nohup`](https://www.gnu.org/software/coreutils/manual/html_node/nohup-invocation.html)

## Existing workstation fit

The repository keeps SSH login freshness separate from process ownership:
eligible interactive logins run a bounded check and return to a plain shell.
The workstation declares AoE's web dashboard and LAN proxy as systemd user
units with explicit `PATH`, restart, and socket policies; the documented
Ansible setup enables user lingering. These are useful precedents for both
options, but neither should be conflated with the Sandcastle run itself.
[SSH login contract](../../README.md#login-freshness-notices),
[workstation user units](../../home/workstation.nix),
[workstation operating contract](../../README.md#workstation-agent-of-empires)

The separation should be:

- `main` tmux session: an explicit operator-managed target, with one AoE
  dashboard window;
- `main:sandcastle-<repo>-<run>` tmux window: one foreground Sandcastle process;
- `.sandcastle/logs/`: authoritative run-event history produced by Sandcastle;
- `.sandcastle/worktrees/`, branches, patches, and captured Codex sessions:
  Sandcastle's existing code/recovery artifacts;
- AoE user service: browser dashboard for AoE-owned agent sessions, not a
  generic process supervisor for Sandcastle.

## Transient-systemd fallback shape

If the pilot chooses systemd instead, the launch should be equivalent to:

```bash
systemd-run --user \
  --unit=sandcastle-<repo>-<run> \
  --description='Sandcastle <repo> <run>' \
  --property=Type=exec \
  --remain-after-exit \
  --working-directory=/absolute/path/to/repo \
  --setenv=PATH \
  /absolute/path/to/repo/<repo-owned-sandcastle-launcher>
```

Inspect it with:

```bash
systemctl --user status sandcastle-<repo>-<run>.service
journalctl --user-unit sandcastle-<repo>-<run>.service --follow
```

`--setenv=PATH` deliberately imports only the caller's `PATH`; Sandcastle's
ignored `.sandcastle/.env` remains responsible for its declared credentials.
After recording the outcome, `systemctl --user stop
sandcastle-<repo>-<run>.service` releases the retained unit. The final launcher
must be tested from the user-manager environment because the current workstation
units already demonstrate that noninteractive services need an explicit tool
path.

## Decision boundary

Choose a tmux window now because the pilot values minimal setup and may need live
inspection. Choose transient systemd instead only if the desired operator
experience is explicitly command/status/journal based and no PTY reattachment is
needed. Do not add a permanent service, AoE custom integration, or automatic
restart until actual pilot use demonstrates a requirement beyond one detached
run.
