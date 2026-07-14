# Repository-only metadata in a chezmoi repository

Researched 2026-07-14 against the official chezmoi and Git documentation.

## Conclusion

There are two different kinds of “not relevant to dotfiles,” and they need different handling:

1. **Repository metadata that should be committed and visible on GitHub, but not applied to `$HOME`** — keep it in the repository and exclude it with `.chezmoiignore`. This is the right treatment for `README.md`, `BOOTSTRAP.md`, `docs/agents/`, published research notes, `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `CONTEXT.md`, and ADRs.
2. **Private or machine-local material that should not be published to GitHub either** — keep it outside the repository, or add it to `.git/info/exclude`; if it remains inside chezmoi's source state, it must also be excluded from chezmoi. Git and chezmoi exclusions solve separate problems.

For this repository, the lowest-risk immediate choice is to retain the current layout and declare the complete repository-documentation surface in `.chezmoiignore`. A `.chezmoiroot` migration is cleaner if the repository is going to accumulate a large amount of non-dotfile content, but it is a broader reorganization and the official guide specifically positions it as the alternative when maintaining `.chezmoiignore` becomes tiresome. [Official source-directory customization guide](https://www.chezmoi.io/user-guide/advanced/customize-your-source-directory/)

## What chezmoi does

### `.chezmoiignore`: committed, but not applied

The official chezmoi guide demonstrates `README.md` as the first example of a source-repository file that should be ignored rather than installed. In other words, published repository documentation is an explicitly documented `.chezmoiignore` use case. [Official machine-differences guide](https://www.chezmoi.io/user-guide/manage-machine-to-machine-differences/#ignore-files-or-a-directory-on-different-machines)

`.chezmoiignore` has several non-obvious rules:

- Patterns are matched against the **target path**, not the encoded source path. For example, the source entry `dot_config/fish` must be matched as `.config/fish`, while `docs/agents` happens to have the same spelling in both states.
- It is interpreted as a Go template even when its name does not end in `.tmpl`.
- Matching a directory and matching its contents are separate. The reference explicitly says `backups/` ignores the directory but not its contents, while `backups/**` ignores the contents but not the directory. Use both lines to exclude a whole subtree.
- A leading `!` negates a pattern, and negations take priority.
- `#` begins a comment. A `#` later in a line counts as a comment only when preceded by whitespace.
- A nested `.chezmoiignore` applies only to its own source-state subtree.

These rules come from the [official `.chezmoiignore` reference](https://www.chezmoi.io/reference/special-files/chezmoiignore/).

`.chezmoiignore` affects chezmoi's target state only. It does not tell Git to ignore a file, so the file remains commit-able and publishable.

### Automatic special-file exclusions

Chezmoi automatically ignores ordinary files and directories beginning with `.`, except recognized `.chezmoi...` special files and directories. Consequently, `.git/`, `.github/`, and a hypothetical `.scratch/` do not become targets in `$HOME`; visible names such as `README.md`, `AGENTS.md`, `CONTEXT.md`, and `docs/` do. See the official [source-state attribute rule](https://www.chezmoi.io/reference/source-state-attributes/) and [special-files ordering](https://www.chezmoi.io/reference/special-files/).

A hidden repository-notes directory would therefore work technically, but it is a poor default for documentation meant to be discovered and rendered on GitHub. There is no chezmoi-prescribed directory for repository documentation; the official material demonstrates an ordinary `README.md` plus `.chezmoiignore`.

### `.chezmoiroot`: structural separation

A root `.chezmoiroot` file can name a relative subdirectory that is the only source-state root. Repository metadata outside that subdirectory remains in Git but is invisible to chezmoi's target-state construction. `.chezmoiroot` is read before all other source files. [Official `.chezmoiroot` reference](https://www.chezmoi.io/reference/special-files/chezmoiroot/)

This is the strongest long-term separation:

```text
repository root/
├── .chezmoiroot       # contains: source
├── README.md          # GitHub-only
├── docs/              # GitHub-only
└── source/            # chezmoi source state
    ├── .chezmoi.toml.tmpl
    ├── .chezmoiignore
    ├── .chezmoiscripts/
    ├── dot_bashrc.tmpl
    └── ...
```

The migration cost matters: the official guide requires moving managed entries and source-root special files, including `.chezmoi.$FORMAT.tmpl`, into the new root. For this repository, `home` is already a managed source directory (`home/workstation.nix`), so the guide's conventional `home` example would collide with current meaning; use a fresh name such as `source` if this approach is adopted. [Official source-directory customization guide](https://www.chezmoi.io/user-guide/advanced/customize-your-source-directory/)

## This repository's current behavior

The repository currently has no `.chezmoiroot`, so `/home/faviann/repos/dotfiles/codex` itself is the source-state root. Its `.chezmoiignore` contains only this conditional entry:

```gotemplate
{{- if .is_lxc }}
dot_config/fish
{{- end }}
```

That condition does not exclude any repository documentation. It also appears to use the encoded source path rather than the target path required by the reference. If the intent is to suppress all Fish configuration on LXC machines, the separately corrected form would be:

```gotemplate
{{- if .is_lxc }}
.config/fish/
.config/fish/**
{{- end }}
```

A local read-only check with chezmoi v2.70.2 confirmed that these visible source paths are currently managed:

```text
BOOTSTRAP.md
README.md
flake.lock
flake.nix
home/
```

Therefore, absent new ignore rules, chezmoi treats them as targets such as `~/README.md`, `~/BOOTSTRAP.md`, `~/flake.nix`, and `~/home/workstation.nix`. Once `docs/` is added, it likewise becomes a target subtree unless ignored. This was verified with:

```bash
chezmoi -S "$PWD" managed --path-style=source-relative --tree
```

The README describes the flake as being built from the repository clone, which strongly suggests `flake.nix`, `flake.lock`, and `home/` are repository infrastructure rather than intended `$HOME` targets. That is an inference from this repository, not a universal chezmoi convention.

## Practical recommendation for this repository

### 1. Publish all project documentation, but exclude it from `$HOME`

Add this unconditional block to the root `.chezmoiignore`, outside the `.is_lxc` conditional:

```text
# Repository-only documentation and agent metadata
README.md
BOOTSTRAP.md
AGENTS.md
CLAUDE.md
CONTRIBUTING.md
CONTEXT.md
CONTEXT-MAP.md
docs/
docs/**
```

Including names that do not exist yet is harmless and prevents a future agent or contributor from accidentally turning a conventional repository file into a home-directory target. Ignoring all of `docs/`, rather than only `docs/agents/`, also covers `docs/research/` and future `docs/adr/` consistently.

If the intended policy is deliberately narrower, the minimum setup-specific alternative is:

```text
docs/agents/
docs/agents/**
docs/research/
docs/research/**
```

The broader documentation block is recommended because `README.md` and `BOOTSTRAP.md` are already demonstrably managed, and the planned domain layout introduces more repository-only files than `docs/agents/` alone.

### 2. Include the existing repository infrastructure in the inventory

Unless this repository intentionally installs a flake and a literal `home/` directory at the top of every user's home directory, add:

```text
# Repository-only Home Manager source
flake.nix
flake.lock
home/
home/**
```

This is best treated as part of the same cleanup, but should be confirmed separately from the agent-skill setup because it changes the pre-existing chezmoi target inventory.

### 3. Keep truly local-only notes out of both systems

For notes that must not reach GitHub, the safest choice is to store them outside this repository. If they need to live in the working tree, add a repository-local pattern to `.git/info/exclude`. Git's official documentation designates `$GIT_COMMON_DIR/info/exclude` for files specific to one user's workflow that should not be shared with other clones. It also warns that ignore rules do not affect files already tracked. [Official `gitignore` documentation](https://git-scm.com/docs/gitignore)

For example, because the recommended chezmoi block already excludes all of `docs/`, a private local research area needs only this Git-local entry:

```gitignore
/docs/research/local/
```

Alternatively, a root `.scratch/` directory is automatically ignored by chezmoi because it is dot-prefixed, but it still needs this in `.git/info/exclude` to remain unpublished:

```gitignore
/.scratch/
```

Do not rely on `.git/info/exclude` alone for a visible path elsewhere in the chezmoi source state: Git would stop showing it, but chezmoi could still apply it. Conversely, `.chezmoiignore` alone keeps a file out of `$HOME` but leaves it available to Git and GitHub.

## Verification before applying

After editing `.chezmoiignore`, verify the rendered ignore set and managed source inventory from the repository root:

```bash
chezmoi -S "$PWD" ignored --tree
chezmoi -S "$PWD" managed --path-style=source-relative --tree
```

`chezmoi ignored` is the official command for listing ignored entries. [Official `ignored` command reference](https://www.chezmoi.io/reference/commands/ignored/)

The repository-only paths should appear in `ignored` and disappear from `managed`. Then preview all target changes without writing:

```bash
chezmoi -S "$PWD" apply --dry-run --verbose
```

Dry-run mode never modifies the destination, and verbose mode reports the proposed operations. [Official global flags reference](https://www.chezmoi.io/reference/command-line-flags/global/)

This repository's secret templates call Bitwarden, so the final dry run may require an unlocked/configured Bitwarden session. The `ignored` and `managed` checks are the focused verification for repository metadata and did not require applying changes.
