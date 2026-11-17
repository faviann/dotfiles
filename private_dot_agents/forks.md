Classify a clone by the original repo's owner (`gh api user/memberships/orgs/<owner> --jq .role`):

| Owner | Kind | Remotes | PRs target |
|---|---|---|---|
| me | my repo | `origin` | `origin` |
| an org I belong to | contribution fork | `origin` = my fork, `upstream` = theirs | `upstream` |
| an org I belong to | direct clone | `origin` = theirs | `origin` |
| anyone else | personal fork | `origin` = my fork, `source` = theirs | `origin` |

- Fix mismatched remotes before working: rename them, or `gh repo fork --remote` when the fork is missing, then `gh repo set-default` to the PR target. Tell me the kind.
- Sync from `source` only when I ask: branch from the usual base, merge a `source` tag, open a PR.
