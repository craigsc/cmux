# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is cmux

cmux is a pure Bash shell tool that manages git worktree lifecycles for running parallel Claude Code sessions. Each worktree gets its own isolated working directory so multiple Claude agents can work on the same repo simultaneously.

## Architecture

**Single-file shell tool** — all logic lives in `cmux.sh` (~560 lines), which is sourced into the user's shell (bash/zsh). There is no build step, no dependencies, and no test suite.

**Function structure:**
- `cmux()` — public dispatcher, routes subcommands to `_cmux_<cmd>` functions
- `_cmux_*()` — private functions: `_cmux_new`, `_cmux_start`, `_cmux_cd`, `_cmux_ls`, `_cmux_merge`, `_cmux_rm`, `_cmux_rm_all`, `_cmux_init`
- Helper functions: `_cmux_repo_root`, `_cmux_safe_name`, `_cmux_worktree_dir`, `_cmux_spinner_start/stop`

**Key design patterns:**
- Idempotent operations (e.g. `cmux new` reuses existing worktrees)
- Context-aware: `cmux rm` and `cmux merge` with no args detect the current worktree from `$PWD`
- Branch name sanitization: `feature/foo` → `feature-foo` for directory names
- Worktrees live under `.worktrees/<safe-branch-name>/` in the repo root

**Setup hook system:** `.cmux/setup` is an executable bash script that runs after worktree creation. It handles project-specific init (symlink secrets, install deps, codegen). `cmux init` uses Claude CLI (`claude -p`) to auto-generate this hook.

## Key files

- `cmux.sh` — the entire application
- `install.sh` — curl-pipe installer that downloads cmux.sh to `~/.cmux/` and adds source line to shell RC
- `.cmux/setup` — project-specific worktree setup hook (committed to repo)
- `examples/setup-node` — example setup hook for Node.js projects

## Shell conventions

- 2-space indentation
- Functions prefixed `_cmux_` for internal, `cmux` for public
- Zsh compatibility: uses `setopt localoptions nomonitor` where needed for job control
- Error handling: validate inputs, check `command -v`, guard with `|| return 1`
- No `set -e` in cmux.sh (it's sourced, not executed); install.sh uses `set -e`

## QA — mandatory before considering any task done

Always self-test changes to cmux.sh before finishing work. Source the file in a bash subshell and run the affected commands to verify correct output and behavior:

```bash
bash -c 'source /path/to/cmux.sh && cmux <subcommand> [args]'
```

Test thoroughly: check happy paths, error paths, flag combinations, and edge cases (no args, bad input, missing worktrees, etc.). Do not consider a task complete until you have verified the changes work.
