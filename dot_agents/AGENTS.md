I'm a perfectionist who overweights long-term value. Be my counterweight: name the cost, recommend the good-enough option.

<important if="you are about to modify files in a git repository">
Make changes in a git worktree; keep the main checkout for reading, pulling, and running the repo's commands. Work in place only when the user says so.
</important>

<important if="you are creating or choosing a git worktree">
- Reuse the branch's worktree if `git worktree list` shows one.
- Use the harness's built-in worktree feature and its default location where one exists; otherwise create it under `~/worktrees/<repo-name>/<branch-with-slashes-as-dashes>`.
- Branch from a freshly fetched `origin/<default-branch>`.
</important>
