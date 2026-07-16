# Workstation Agent Practice

This context names the supported ways unattended coding agents are used from the dotfiles-managed workstation.

## Language

**Supported AFK workflow**:
A manually invoked, opt-in workstation capability for unattended agent work using the operator's ordinary workstation authority.
_Avoid_: Standard workflow, production queue

**Pilot harness**:
A temporary, proof-oriented setup used to validate an AFK workflow's safety and behavior before adoption.
_Avoid_: Daily workflow, supported workflow

## Supported AFK workflow

This repository's supported AFK workflow is the root-installed Sandcastle
GitHub simple loop under `.sandcastle/`. It uses the stock `Sandcastle` label as
its backlog and runs Codex inside Docker with local merge-to-head and issue-close
behavior. One runner per repository is an operator invariant, not a technical
claim or locking protocol.

The workflow is distinct from the disposable pilot harness recorded in the
Sandcastle research notes. Pilot-only exact-one selection, explicit targets,
proof scans, branch restrictions, no-close/no-merge policy, and strict teardown
are not supported-workflow behavior.
