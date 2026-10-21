# Project instructions

## Git discipline

- **Never create commits on your own initiative.** Do not run `git commit`,
  `git merge`, `git rebase`, `git cherry-pick`, `git revert`, or any other
  command that creates or rewrites commits until the user has explicitly
  asked for a commit in the current session.
- "The task is done" is not commit permission. When work is complete,
  stop at a clean, verified working tree: run the checks, summarize the
  changes (`git status`, `git diff --stat`), and wait for the user's
  explicit go-ahead.
- Branch creation (`git checkout -b`, `git switch -c`) when the user asks
  for a branch is allowed — it creates no commits.
- Staging files is fine only as part of a commit the user has approved;
  otherwise leave the index untouched.
- `TODO-PROBLEMS.md` is intentionally untracked — never add, commit, or
  delete it.
