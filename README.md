# cmux — tmux for Claude Code

Run a fleet of Claude agents on the same repo — each in its own worktree, zero conflicts, one command each.

(Because you wanna go fast without losing your goddamn mind.)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/craigsc/cmux/main/install.sh | sh
```

## Quick start

```sh
cmux new feature-auth       # create worktree + branch, run setup hook, launch a fresh Claude session
cmux new fix-typo            # spin up a second agent in parallel — totally isolated
cmux start feature-auth      # resume exactly where you left off (picks up your last conversation)
```

## Commands

| Command | What it does |
|---------|-------------|
| `cmux new <branch>` | Create branch + worktree, run setup hook, launch a **fresh** Claude session |
| `cmux start <branch>` | cd into worktree and **resume** the most recent Claude conversation |
| `cmux cd [branch]` | cd into a worktree (no args = repo root) |
| `cmux ls` | List active worktrees |
| `cmux merge [branch] [--squash]` | Merge worktree branch into main checkout (no args = current worktree) |
| `cmux rm [branch \| --all]` | Remove a worktree (no args = current, `--all` = every worktree with confirmation) |
| `cmux init [--replace]` | Generate `.cmux/setup` hook using Claude (`--replace` to regenerate) |
| `cmux update` | Update cmux to the latest version |
| `cmux version` | Show current version |

## Workflow

You're building a feature:

```sh
cmux new feature-auth        # agent starts working on auth
```

Bug comes in. No problem — spin up another agent without leaving the first one:

```sh
cmux new fix-payments        # second agent, isolated worktree, independent session
```

Merge the bugfix when it's done:

```sh
cmux merge fix-payments --squash
cmux rm fix-payments
```

Come back tomorrow and pick up the feature work right where you left off:

```sh
cmux start feature-auth      # resumes your last conversation — context intact
```

The key distinction: `new` = fresh conversation, `start` = **same conversation, continued**.

## Setup hook

When `cmux new` creates a worktree, it runs `.cmux/setup` if one exists. This handles project-specific init — symlinking secrets, installing deps, running codegen.

The easy way — let Claude write it for you:

```sh
cmux init
```

Or create one manually:

```bash
#!/bin/bash
REPO_ROOT="$(git rev-parse --git-common-dir | xargs dirname)"
ln -sf "$REPO_ROOT/.env" .env
npm ci
```

See [`examples/`](examples/) for more.

## How it works

- Worktrees live under `.worktrees/<branch>/` in the repo root (add `.worktrees/` to your `.gitignore`)
- Branch names are sanitized: `feature/foo` becomes `feature-foo`
- `cmux new` is idempotent — if the worktree already exists, it just cd's there
- `cmux merge` and `cmux rm` with no args detect the current worktree from `$PWD`
- Pure bash, no dependencies

## Tab completion

Built-in completion for bash and zsh — automatically registered when you source `cmux.sh`, no extra setup.

- `cmux <TAB>` — subcommands
- `cmux start <TAB>` — existing worktree branches
- `cmux cd <TAB>` — existing worktree branches
- `cmux rm <TAB>` — worktree branches + `--all`
- `cmux merge <TAB>` — worktree branches
- `cmux init <TAB>` — `--replace`

## License

MIT
