# Workstation Agent Practice

This context names the supported ways unattended coding agents are used from the dotfiles-managed workstation.

## Language

**Supported AFK workflow**:
A manually invoked, opt-in workstation capability for unattended agent work using the operator's ordinary workstation authority.
_Avoid_: Standard workflow, production queue

**Pilot harness**:
A temporary, proof-oriented setup used to validate an AFK workflow's safety and behavior before adoption.
_Avoid_: Daily workflow, supported workflow

**Support portfolio**:
The bounded set of target repositories for which the supported AFK workflow
promises a zero-AFK-configuration launch experience. The initial portfolio is
dotfiles, homelab-iac, and overmind; other repositories join only after their
needs are observed and deliberately supported.
_Avoid_: Every repository, arbitrary repository

**Repository environment override**:
An exceptional, repository-owned extension to the shared AFK environment for a
target repository whose validation contract cannot run in the common image. It
may specialize the environment, but workstation-owned orchestration and
credentials remain global.
_Avoid_: Repository-local AFK workflow, bespoke launcher

**Workstation configuration freshness**:
Owned by `workstation-setup`; canonical definition lives in homelab-iac's `CONTEXT.md`.
_Avoid_: Home Manager generation check, local freshness algorithm

**Workstation-local Moraine**:
The v1 Moraine deployment whose ingestion, persistence, and query backend all
run under the workstation user without depending on Overmind.
_Avoid_: Shared Moraine, Overmind Moraine

**Moraine central server**:
Moraine's per-user local Unix-socket backend within Workstation-local Moraine.
_Avoid_: Remote backend, central database

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
