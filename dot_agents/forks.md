Classify a clone by the original repo's owner, using my role there (`gh api user/memberships/orgs/<owner> --jq .role`):

| Owner | Kind | Remotes |
|---|---|---|
| me, or an org where I'm admin | my repo | `origin` |
| an org where I'm a member | contribution fork | `origin` = my fork, `upstream` = theirs |
| anyone else | personal fork | `origin` = my fork, `source` = theirs |

- Fix mismatched remotes before working: rename them, or run `gh repo fork --remote` when the fork is missing. Tell me the kind you picked.
- In my repo or a personal fork, PRs target `origin`.
- A contribution fork has a `source` remote only where I added one.
- Sync from `source` only when I ask: branch from the usual base, merge a `source` tag, and open a PR.
