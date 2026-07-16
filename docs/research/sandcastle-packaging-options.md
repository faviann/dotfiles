# Reproducible Sandcastle packaging options for dotfiles

Researched 2026-07-16 against Sandcastle v0.12.0, Node and npm's official
module/install documentation, the Nixpkgs and Home Manager revisions pinned by
this repository, and the repository's existing workstation tooling. Sandcastle
source links are pinned to commit
[`e99f832f26dc9d245c019a9ddd19fa5dee792427`](https://github.com/mattpocock/sandcastle/tree/e99f832f26dc9d245c019a9ddd19fa5dee792427).

## Recommendation

Pilot Sandcastle with **committed, exact-version npm metadata inside each target
repository's `.sandcastle/` directory**, an ignored
`.sandcastle/node_modules/`, and a small repo-root launcher that:

1. restores the locked runtime with `npm --prefix .sandcastle ci` when needed;
2. launches `./.sandcastle/node_modules/.bin/tsx .sandcastle/main.mts` from the
   repository root.

The committed `.sandcastle/package.json` should pin both
`@ai-hero/sandcastle` and `tsx` to exact versions, initially `0.12.0` and
`4.21.0`, and commit the generated `.sandcastle/package-lock.json`. This is the
least-intrusive shape that preserves upstream's repo-scoped workflow and
ordinary Node module resolution without turning a non-Node repository root into
an npm project or adding Sandcastle to the workstation-wide agent toolchain.

This is a packaging decision, not an implementation. The pilot should separately
decide the launcher's name, whether dependency restoration is explicit or
automatic, and how the scaffold is initially generated.

## The module-resolution constraint

Upstream installs Sandcastle in the repository root and generates a
`.sandcastle/main.mts` that imports the bare specifier `@ai-hero/sandcastle`; its
documented launch is `npx tsx .sandcastle/main.mts`.
[Upstream quick start](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/README.md#L19-L52),
[generated next steps](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L643-L690)

Node resolves an ESM bare package import relative to the importing file: it
checks `node_modules/<package>` beside the parent URL and then walks upward.
Therefore `.sandcastle/main.mts` can import Sandcastle from either
`.sandcastle/node_modules` or repository-root `node_modules`.
[Node ESM `PACKAGE_RESOLVE`](https://nodejs.org/api/esm.html#resolution-algorithm-specification)

That same rule excludes ordinary workstation-global npm and Home Manager
installations. A global npm package lives under the configured global prefix,
not in an ancestor `node_modules` directory, and ESM imports do not consult
`NODE_PATH`. PATH can locate a `sandcastle` or `tsx` executable, but it cannot
make the library import in `main.mts` resolve.
[npm folder layout](https://docs.npmjs.com/files/folders.html/),
[Node ESM does not use `NODE_PATH`](https://nodejs.org/api/esm.html#no-node_path)

There is also a subtle reproducibility problem with keeping upstream's literal
`npx tsx .sandcastle/main.mts` command. npm executes a locally installed binary
when it belongs to the current project, but otherwise downloads the requested
package into its cache and adds that cache directory to PATH. A `tsx` binary
installed *below* the current root in `.sandcastle/node_modules/.bin` is not a
root-local binary, so plain root-level `npx tsx ...` can fetch a moving `tsx`
version even while Sandcastle itself resolves from `.sandcastle/node_modules`.
Invoking the locked binary by path avoids that split.
[npm exec behavior](https://docs.npmjs.com/cli/v11/commands/npm-exec/)

## Options compared

| Option | Module resolution | Reproducibility and upgrades | Removal | Maintenance and repository fit |
| --- | --- | --- | --- | --- |
| Upstream repo-root npm install | Works exactly as documented: `.sandcastle/main.mts` walks up to root `node_modules`. | Exact dependency entries plus a committed root lockfile allow frozen `npm ci`; upgrading deliberately changes the manifest and lock. Without exact entries, an install can advance within the declared semver range. | Remove the root manifest/lock if they exist only for Sandcastle, `node_modules`, and `.sandcastle`. | Lowest upstream-specific maintenance, but highest repository intrusion: it makes dotfiles look like a Node project solely to host one orchestration library. That conflicts with the map's standing preference. |
| Isolated npm metadata in `.sandcastle/` | Works naturally because `.sandcastle/node_modules` is adjacent to `main.mts`. Use its locked `tsx` binary directly rather than root-level `npx tsx`. | Same package-lock and `npm ci` guarantees as a root project, scoped to Sandcastle. Upgrades are small, reviewable changes under `.sandcastle/`; Node/npm remain supplied by the flake-pinned workstation profile. | Delete `.sandcastle/` (after preserving any desired workflow or logs); no workstation package state remains beyond npm's disposable cache. | Small launcher convention is local maintenance, but it keeps all Sandcastle-owned code and metadata together and leaves the root non-Node. Best pilot fit. |
| Nix/Home Manager package | A package can expose Sandcastle's CLI on PATH, but that alone does **not** satisfy the ESM import in repo-local `main.mts`. It needs a repo-local symlink, a custom ESM loader, rewritten imports, or packaging the workflow together with the library. | Strongest source/dependency pinning: `buildNpmPackage` builds from a fixed source and `npmDepsHash`, using an offline dependency cache. Upgrades must update source/lock and hashes, then pass the flake build. | Remove the package from `home.packages` and rebuild; old store paths disappear through normal garbage collection. Repo-local compatibility links or generated wrappers would need separate cleanup. | Fits the workstation's declarative base-tool layer, but requires authoring and maintaining a package plus a module-resolution bridge. That machinery is disproportionate for a disposable pilot and couples repo-scoped workflow code to workstation configuration. |
| Workstation-wide global npm tool | The CLI and `tsx` binaries are on PATH, but bare ESM imports do not find global packages. A symlink/loader or changed workflow import is still required. | This repo's updater intentionally installs its npm-managed agent tools at `@latest`, so it optimizes for coordinated current versions rather than per-repository locks. Adding Sandcastle there would make every repo share one mutable version and upgrade event. | Add explicit updater removal behavior or run a global uninstall; repository workflow files still remain. | Superficially matches the existing CLI toolchain, but Sandcastle is a library consumed by repo-local TypeScript, not only a CLI. It also expands the updater's inventory, freshness checks, tests, and failure boundary for a pilot used by only selected repositories. |

## Reproducibility details

The npm lockfile records the exact dependency tree and integrity data. `npm ci`
requires a lockfile, fails rather than rewriting it when it disagrees with
`package.json`, removes an existing `node_modules`, and never writes either
manifest; npm describes the install as frozen.
[npm `ci`](https://docs.npmjs.com/cli/v11/commands/npm-ci/),
[package-lock format](https://docs.npmjs.com/cli/v11/configuring-npm/package-lock-json/)

The v0.12.0 published package is already built ESM with a `sandcastle` binary,
one normal runtime dependency, and optional Daytona/Vercel peers; its exported
Docker and Podman modules are included in the package. Upstream's repository
itself uses npm 10.9.2 and `tsx` 4.21.0, but does not declare a Node engine.
[v0.12.0 package metadata](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/package.json)

The proposed lock fixes JavaScript package contents, not the entire runtime.
Here, Node/npm are supplied by the flake-pinned `nixpkgs` input and Home Manager,
so workstation rebuilds pin that base independently. Docker/Podman, the generated
base image tag, and the unpinned Codex CLI inside upstream's generated image are
separate reproducibility boundaries; choosing `.sandcastle/package-lock.json`
does not solve them.
[workstation package declaration](../../home/workstation.nix),
[flake inputs](../../flake.nix),
[generated Codex Dockerfile](https://github.com/mattpocock/sandcastle/blob/e99f832f26dc9d245c019a9ddd19fa5dee792427/src/InitService.ts#L275-L306)

Nix packaging could close more of the host-side dependency boundary.
`buildNpmPackage` creates a reproducible npm cache, requires an `npmDepsHash`,
and installs package-declared binaries. Home Manager's `home.packages` then puts
the resulting package in the user environment. Neither mechanism changes Node's
repo-relative ESM lookup, which is why the extra bridge remains necessary.
[Nixpkgs `buildNpmPackage`](https://nixos.org/manual/nixpkgs/unstable/#javascript-buildNpmPackage),
[pinned Home Manager `home.packages` definition](https://github.com/nix-community/home-manager/blob/e4419d3123b780d5f4c0bceeace450424387638c/modules/home-environment.nix#L164-L171)

## Operational shape of the pilot

The packaging shape should establish these invariants:

- `.sandcastle/package.json` and `.sandcastle/package-lock.json` are committed;
- both direct dependencies use exact versions rather than `latest`, tags, or
  range operators;
- `.sandcastle/node_modules/` remains ignored and is reconstructed only with
  `npm --prefix .sandcastle ci`;
- launch occurs from the target repository root so Sandcastle retains the
  expected working directory;
- the launcher executes the `.sandcastle`-local `tsx` path, never an ambient
  global binary or an implicitly downloaded `npx` package;
- upgrades are explicit manifest/lock changes reviewed per repository; and
- removal does not touch the workstation-wide updater or Home Manager profile.

This adds two small metadata files and one launcher convention to each opted-in
repository. In return it preserves the upstream workflow shape, gives each repo
an independently reviewable Sandcastle version, and keeps the experiment
reversible without first building a general Nix integration.

## Why not promote it to workstation tooling yet

The current workstation layer installs Node/npm declaratively through Home
Manager, then uses `update-agent-tools` for a coordinated set of interactive
agent CLIs and ACP adapters under `~/.local`. That updater validates one global
npm prefix, discovers current registry releases, installs every managed package
at `@latest`, and treats their install/activation as one maintenance unit.
[workstation contract](../../README.md#workstation-agent-of-empires),
[agent-tool updater](../../dot_local/bin/executable_update-agent-tools)

Sandcastle's relevant interface here is its **importable library** inside a
repository-owned workflow, so global CLI availability does not meet the runtime
need. Promotion would become reasonable only if repeated pilots establish a
stable workstation-level wrapper/API and the project intentionally accepts one
shared upgrade cadence. Until then, isolated repo metadata has lower maintenance
cost and a cleaner removal story.
