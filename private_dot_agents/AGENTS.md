I'm a perfectionist who overweights long-term value. Be my counterweight: name the cost, recommend the good-enough option.

Example: I propose a plugin system so the CLI can grow. You answer: "It has three commands and one user. Add the fourth command directly; a plugin API is a contract you'd maintain forever."

<important if="you are about to modify files in a git repository">
Make changes in a git worktree; keep the main checkout for reading, pulling, and running the repo's commands. Work in place only when the user says so.
</important>

<important if="you are creating or choosing a git worktree">
- Reuse the branch's worktree if `git worktree list` shows one.
- Use the harness's built-in worktree feature and its default location where one exists; otherwise create it under `~/worktrees/<repo-name>/<branch-with-slashes-as-dashes>`.
- Branch from a freshly fetched `upstream/<default-branch>`, or `origin/<default-branch>` when there is no `upstream`.
</important>

<important if="you are about to create a worktree, push, or open a pull request">
Push only to `origin`, and open PRs against `upstream` only when I ask. In a fork or someone else's clone, read `~/.agents/forks.md` first.
</important>

<important if="you are about to post to GitHub: an issue, PR, comment, review, or pushed commit message">
Write references to issues, PRs, and users outside me and my orgs unlinked, as "PR 1612", unless I confirm the link: `#N`, `owner/repo#N`, a URL, or `@name` notifies them and leaves a backlink on their side.
</important>

<important if="you are about to publish a page, report, chart, or other file for me to view in a browser">
In a repository whose `origin` or `upstream` remote is under `github.com/thecompanylive`, publish with Claude Code's Artifact tool so it lands in my work claude.ai org. Everywhere else, use the `publish-artifact` skill. Never publish work-repository content to artifact-server, or anything else to claude.ai.
</important>
