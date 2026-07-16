# Sandcastle and Codex subscription authentication

## Finding

Yes—upstream Sandcastle has discussed and exercised Codex ChatGPT-subscription
authentication through `~/.codex/auth.json` several times. It is **not a
first-class Codex-provider option** in the pinned Sandcastle v0.12.0 release,
but v0.12.0 has the generic Docker/Podman mount support needed to implement it.
A real container smoke test is still a hard prerequisite: upstream history is
strong prior evidence, not proof that this workstation's current `auth.json`
and pinned Codex CLI work together.

## Upstream history

- [PR “Add Codex ChatGPT Subscription Option”](https://github.com/mattpocock/sandcastle/pull/235)
  implemented `codex(model, { provider: "chatgpt" })`, mounted `~/.codex`,
  checked for `auth.json`, and reported a successful end-to-end run. The PR was
  closed without merge. The maintainer preferred putting credentials in a
  generic sandbox mount instead of making mounts part of the agent-provider
  interface; the exact proposed shape is in the
  [maintainer's review](https://github.com/mattpocock/sandcastle/pull/235#issuecomment-4238117206).
- The associated [ChatGPT-subscription PRD](https://github.com/mattpocock/sandcastle/issues/236)
  records an implementation finding that no `model_provider="chatgpt"` override
  is needed: Codex automatically detects file-based login state in
  `~/.codex/auth.json`. The maintainer closed the PRD as
  [`wontfix` in favor of the generic-mount design](https://github.com/mattpocock/sandcastle/issues/236#issuecomment-4238997256).
- [“Support custom bind-mounts”](https://github.com/mattpocock/sandcastle/issues/237)
  then landed the maintainer's chosen abstraction: `docker()` and `podman()`
  accept `{ hostPath, sandboxPath, readonly? }` mounts with host `~` expansion.
- [“Figure out Codex + Subscription”](https://github.com/mattpocock/sandcastle/issues/488)
  remains open as a documentation issue. Reports there include two relevant
  working patterns: mounting host Codex state read-only and copying
  `auth.json` into a writable container `CODEX_HOME`
  ([example](https://github.com/mattpocock/sandcastle/issues/488#issuecomment-4354949185)),
  and using a separate project-scoped Codex auth directory created through
  `codex login --device-auth`
  ([example](https://github.com/mattpocock/sandcastle/issues/488#issuecomment-4631089970)).
  A duplicate issue also reports the read-only-host/copy-on-start workaround
  working in practice
  ([“Codex provider auth is unclear”](https://github.com/mattpocock/sandcastle/issues/596#issuecomment-4403185638)).
- Directly mounting only `auth.json` once failed because Docker created its
  container-side parent directory with unusable ownership
  ([original report](https://github.com/mattpocock/sandcastle/issues/499)).
  Upstream fixed that in v0.5.10 for Docker and Podman, explicitly testing
  `/home/agent/.codex/auth.json`; the
  [upstream closeout](https://github.com/mattpocock/sandcastle/issues/499#issuecomment-4576163150)
  identifies the fix and versions. The fix is present in the pinned
  [v0.12.0 changelog](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/CHANGELOG.md#L190-L195)
  and its Docker test uses that exact target
  ([source](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/sandboxes/docker.test.ts#L633-L669)).

## State of pinned v0.12.0

At commit
[`e99f832f26dc9d245c019a9ddd19fa5dee792427`](https://github.com/mattpocock/sandcastle/tree/e99f832f26dc9d245c019a9ddd19fa5dee792427):

- `docker({ mounts: [...] })` is public and documented
  ([README example](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L135-L149)).
- `codex()` has no ChatGPT/subscription option; its options are effort,
  provider environment, session capture/storage, and approval reviewer
  ([source](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/AgentProvider.ts#L749-L780)).
- `sandcastle init` still scaffolds `OPENAI_KEY=` for Codex
  ([source](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L433-L441));
  the README does not document the subscription-auth recipe. The open
  [documentation umbrella](https://github.com/mattpocock/sandcastle/issues/483)
  explicitly points to “Figure out Codex + Subscription.”

## Implication for the pilot spike

Use subscription authentication only—do not set `OPENAI_KEY` or another API
key. Stage the minimum required host login state into a temporary directory,
mount that staging directory read-only, and copy `auth.json` into a fresh,
writable container `CODEX_HOME`. Then, inside the actual pinned Sandcastle
image, require both `codex login status` and one harmless authenticated Codex
command to succeed. Verify that the host file is unchanged, secrets do not
appear in logs or the worktree, and the staged/container copies disappear on
cleanup. Failure blocks the disposable pilot and triggers redesign; it must not
fall back to API-key authentication.
