# cmux — tmux for Claude Code

Worktree lifecycle manager for parallel [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions.

Run multiple Claude agents in parallel on the same repo — each in its own git worktree with isolated working directory, dependencies, build artifacts, etc - completely configurable via an auto-generating per-project setup hook.

## Why

Because you wanna go fast without losing your goddamn mind.

Claude Code works best when it has full ownership of the working directory. When you want multiple agents working on different tasks simultaneously, you need separate checkouts. Git worktrees are the perfect primitive for this — they share the same `.git` database but give each agent its own directory tree.

cmux wraps the worktree lifecycle into a single simple command and makes it effortless to manage the complete worktree lifecycle so Claude can focus on what it does best.

## Install

### Quickstart

```sh
curl -fsSL https://raw.githubusercontent.com/craigsc/cmux/main/install.sh | sh
```

### Manual

1. Download `cmux.sh`
2. Source it in your shell config (`~/.bashrc` or `~/.zshrc`):

```sh
source /path/to/cmux.sh
```

3. Run `cmux init` in your project folder to generate a setup hook

## Usage

```

cmux new <branch> — Create worktree, run setup hook, launch claude
cmux start <branch> — Launch claude in existing worktree
cmux cd [branch] — cd into worktree (no args = repo root)
cmux ls — List worktrees
cmux rm [branch] — Remove worktree (no args = current)
cmux init — Generate .cmux/setup hook using Claude

```

### Typical workflow

```sh
# Start a new agent on a feature branch
cmux new feature-foo

# In another terminal, start another agent
cmux new feature-bar

# List project worktrees
cmux ls

# Jump directly back into previous Claude Code session
cmux start feature-foo

# cd into a worktree folder
cmux cd feature-foo
cmux cd feature-bar

# Merge worktree back into project root
#TODO

# Clean up worktree when done
cmux rm feature-foo
```

## Project setup hook

When `cmux new` creates a worktree, it looks for an executable `.cmux/setup` script in the new worktree. This runs any project-specific setup — installing dependencies, symlinking secrets, generating code, etc.

Create `.cmux/setup` in your repo:

```bash
#!/bin/bash
REPO_ROOT="$(git rev-parse --git-common-dir | xargs dirname)"

# Symlink secrets that aren't in git
ln -sf "$REPO_ROOT/.env" .env

# Install dependencies
npm ci
```

Make it executable:

```bash
chmod +x .cmux/setup
```

See [`examples/`](examples/) for more.

### `cmux init`

Don't want to write the setup hook yourself? Run `cmux init` in your repo and Claude will analyze the project and generate `.cmux/setup` for you:

```sh
cmux init
# → Analyzing repo to generate .cmux/setup...
# → Created .cmux/setup
# → Review it, then commit to your repo.
```

## Gitignore

Add `.worktrees/` to your project's `.gitignore`:

```
.worktrees/
```

## How it works

- Worktrees are created under `.worktrees/<branch>/` in the repo root
- Branch names are sanitized: `feature/foo` becomes `feature-foo`
- `cmux new` is idempotent — if the worktree exists, it just `cd`s there
- `cmux rm` with no args detects the current worktree and removes it
- Works from anywhere inside the repo or its worktrees

## License

MIT
