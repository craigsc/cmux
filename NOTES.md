# Release notes

Add a new `## X.Y.Z` section at the top for each release. `cmux` reads this
file to show what's new after an update and in `cmux version`.

## 0.1.4
- Release notes: run "cmux version" anytime, and the first run after an update shows what's new
- `cmux new` now branches from the repo's default branch, with a new `--from` flag to override
- `cmux ls` shows merge status per worktree (`[merged]` / `[ahead N]`)
- `cmux new` and `cmux start` accept `-p <prompt>` to seed Claude with an initial prompt
- Pass extra flags to the Claude CLI via `--` (e.g. `cmux new foo -- --model sonnet`)
- New `.cmux/teardown` hook runs when a worktree is removed
- Configurable worktree layouts: `nested` (default), `outer-nested`, `sibling` — see `cmux config`
- Fixed: repo-root resolution no longer triggers direnv
