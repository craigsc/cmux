# cmux — tmux for Claude Code

Run a fleet of Claude agents on the same repo — each in its own worktree, zero conflicts, one command each.

Claude Code works best when it has full ownership of the working directory. Want two agents working in parallel? They'll stomp on each other — conflicting edits, dirty state, broken builds. You need separate checkouts.

[Git worktrees](https://git-scm.com/docs/git-worktree) are the perfect primitive for this. They share the same `.git` database but give each agent its own directory tree — no cloning, no syncing, branches stay in lockstep. cmux wraps the entire worktree lifecycle into single commands so you can spin agents up, jump between them, and tear them down without thinking about it.

You wanna go fast without losing your goddamn mind. This is how.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/craigsc/cmux/main/install.sh | sh
```

Then add `.worktrees/` to your `.gitignore`:

```sh
echo '.worktrees/' >> .gitignore
```

## Quick start

```sh
cmux new feature-auth       # creates worktree + branch, runs setup hook, opens Claude
```

That's it. One command, one agent, fully isolated. See [Workflow](#workflow) for the full loop.

## Commands

| Command | What it does |
|---------|-------------|
| `cmux new <branch>` | Create **new** worktree + branch, run setup hook, launch Claude |
| `cmux start <branch>` | **Continue** where you left off in an existing worktree |
| `cmux cd [branch]` | cd into a worktree (no args = repo root) |
| `cmux ls` | List active worktrees |
| `cmux merge [branch] [--squash]` | Merge worktree branch into your primary checkout (no args = current worktree) |
| `cmux rm [branch \| --all]` | Remove a worktree and its branch (no args = current, `--all` = every worktree with confirmation) |
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
cmux start feature-auth      # picks up right where you left off
```

The key distinction: `new` = new worktree, new session. `start` = existing worktree, continuing session.

## Setup hook

When `cmux new` creates a worktree, it runs `.cmux/setup` if one exists. This handles project-specific init — symlinking secrets, installing deps, running codegen. If no setup hook exists, you'll be prompted to generate one.

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

- Worktrees live under `.worktrees/<branch>/` in the repo root
- Branch names are sanitized: `feature/foo` becomes `feature-foo`
- `cmux new` is idempotent on the worktree — if it already exists, it skips creation and setup, but still launches a new Claude session
- `cmux merge` and `cmux rm` with no args detect the current worktree from `$PWD`
- Pure bash — just git and the Claude CLI

## Tab completion

You never have to remember branch names. Built-in completion for bash and zsh — automatically registered when you source `cmux.sh`, no extra setup.

- `cmux <TAB>` — subcommands
- `cmux start <TAB>` — existing worktree branches
- `cmux cd <TAB>` — existing worktree branches
- `cmux rm <TAB>` — worktree branches + `--all`
- `cmux merge <TAB>` — worktree branches
- `cmux init <TAB>` — `--replace`

## License

MIT
