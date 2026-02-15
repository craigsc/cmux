# cmux — tmux for Claude Code
#
# Worktree lifecycle manager for parallel Claude Code sessions.
# Each agent gets its own worktree — no conflicts, one command each.
#
# Commands:
#   cmux new <branch>     — New worktree + branch, run setup hook, launch Claude
#   cmux start <branch>   — Continue where you left off in an existing worktree
#   cmux cd [branch]      — cd into worktree (no args = repo root)
#   cmux ls               — List worktrees
#   cmux merge [branch]   — Merge worktree branch into primary checkout
#   cmux rm [branch]      — Remove worktree + branch (no args = current)
#   cmux rm --all         — Remove ALL worktrees (requires confirmation)
#   cmux init [--replace] — Generate .cmux/setup hook using Claude
#   cmux update           — Update cmux to the latest version
#   cmux version          — Show current version

_CMUX_DOWNLOAD_URL="https://github.com/craigsc/cmux/releases/latest/download"
CMUX_VERSION="unknown"
[[ -f "$HOME/.cmux/VERSION" ]] && CMUX_VERSION="$(<"$HOME/.cmux/VERSION")"

cmux() {
  local cmd="$1"
  shift 2>/dev/null

  _cmux_check_update

  case "$cmd" in
    new)     _cmux_new "$@" ;;
    start)   _cmux_start "$@" ;;
    cd)      _cmux_cd "$@" ;;
    ls)      _cmux_ls "$@" ;;
    merge)   _cmux_merge "$@" ;;
    rm)      _cmux_rm "$@" ;;
    init)    _cmux_init "$@" ;;
    update)  _cmux_update "$@" ;;
    version) echo "cmux $CMUX_VERSION" ;;
    --help|-h|"")
      echo "Usage: cmux <new|start|cd|ls|merge|rm|init|update> [branch]"
      echo ""
      echo "  new <branch>     New worktree + branch, run setup hook, launch Claude"
      echo "  start <branch>   Continue where you left off in an existing worktree"
      echo "  cd [branch]      cd into worktree (no args = repo root)"
      echo "  ls               List worktrees"
      echo "  merge [branch]   Merge worktree branch into primary checkout"
      echo "  rm [branch]      Remove worktree + branch (no args = current)"
      echo "  rm --all         Remove ALL worktrees (requires confirmation)"
      echo "  init [--replace] Generate .cmux/setup hook using Claude"
      echo "  update           Update cmux to the latest version"
      echo "  version          Show current version"
      return 0
      ;;
    *)
      echo "Unknown command: $cmd"
      echo "Run 'cmux --help' for usage."
      return 1
      ;;
  esac
}

# ── Helpers ──────────────────────────────────────────────────────────

# Get the repo root from anywhere (works inside worktrees too)
_cmux_repo_root() {
  local git_common_dir
  git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  # --git-common-dir returns the .git dir; parent is repo root
  (cd "$(dirname "$git_common_dir")" && pwd)
}

# Sanitize branch name: slashes become hyphens
_cmux_safe_name() {
  echo "${1//\//-}"
}

# Resolve worktree directory for a branch
_cmux_worktree_dir() {
  local repo_root="$1"
  local safe_name="$(_cmux_safe_name "$2")"
  echo "$repo_root/.worktrees/$safe_name"
}

_cmux_spinner_start() {
  # Suppress zsh job control messages ([N] PID)
  [[ -n "$ZSH_VERSION" ]] && setopt localoptions nomonitor
  ( while true; do
      for c in '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'; do
        printf "\b%s" "$c"
        sleep 0.08
      done
    done ) &
  _CMUX_SPINNER_PID=$!
}

_cmux_spinner_stop() {
  [[ -z "$_CMUX_SPINNER_PID" ]] && return
  [[ -n "$ZSH_VERSION" ]] && setopt localoptions nomonitor
  kill "$_CMUX_SPINNER_PID" 2>/dev/null
  wait "$_CMUX_SPINNER_PID" 2>/dev/null
  printf "\b \n"
  unset _CMUX_SPINNER_PID
}

_cmux_check_update() {
  local cache_dir="$HOME/.cmux"
  local version_file="$cache_dir/.latest_version"
  local check_file="$cache_dir/.last_check"

  # Show notice if a newer version is known
  if [[ -f "$version_file" ]]; then
    local latest
    latest="$(<"$version_file")"
    if [[ -n "$latest" && "$latest" != "$CMUX_VERSION" ]]; then
      printf 'cmux: update available (%s → %s). Run "cmux update" to upgrade.\n' \
        "$CMUX_VERSION" "$latest"
    fi
  fi

  # Throttle: check at most once per day (86400 seconds)
  local now
  now="$(date +%s)"
  if [[ -f "$check_file" ]]; then
    local last_check
    last_check="$(<"$check_file")"
    if (( now - last_check < 86400 )); then
      return
    fi
  fi

  # Background fetch — no shell startup cost
  [[ -n "$ZSH_VERSION" ]] && setopt localoptions nomonitor
  {
    local v
    v="$(curl -fsSL "${_CMUX_DOWNLOAD_URL}/VERSION" 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$v" ]] && printf '%s' "$v" > "$version_file"
    printf '%s' "$now" > "$check_file"
  } &>/dev/null &
  disown 2>/dev/null
}

# ── Subcommands ──────────────────────────────────────────────────────

_cmux_new() {
  if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Usage: cmux new <branch>"
    echo ""
    echo "  Create a new worktree and branch, run setup hook, and launch Claude Code."
    return 0
  fi
  if [[ -z "$1" ]]; then
    echo "Usage: cmux new <branch>"
    return 1
  fi

  local branch="${*// /-}"
  local repo_root
  repo_root="$(_cmux_repo_root)" || { echo "Not in a git repo"; return 1; }

  local worktree_dir
  worktree_dir="$(_cmux_worktree_dir "$repo_root" "$branch")"

  # Idempotent: if worktree already exists, just cd there
  if [[ -d "$worktree_dir" ]]; then
    echo "Worktree already exists: $worktree_dir"
    cd "$worktree_dir"
  else
    # Ensure .worktrees directory exists
    mkdir -p "$repo_root/.worktrees"
    git -C "$repo_root" worktree add "$worktree_dir" -b "$branch" || return 1
    cd "$worktree_dir"

    # Run project-specific setup hook
    if [[ -x "$worktree_dir/.cmux/setup" ]]; then
      echo "Running .cmux/setup..."
      "$worktree_dir/.cmux/setup"
    elif [[ -x "$repo_root/.cmux/setup" ]]; then
      echo "Running .cmux/setup from repo root (not yet committed to branch)..."
      "$repo_root/.cmux/setup"
      echo "Tip: commit .cmux/setup so it's available in new worktrees automatically."
    else
      echo "No .cmux/setup found — worktree will skip project-specific setup."
      printf "Run 'cmux init' to generate one? (y/N) "
      read -r reply
      if [[ "$reply" =~ ^[Yy]$ ]]; then
        _cmux_init
        if [[ -x "$repo_root/.cmux/setup" ]]; then
          echo "Running .cmux/setup..."
          "$repo_root/.cmux/setup"
        fi
      fi
    fi
  fi

  echo "Worktree ready: $worktree_dir"
  claude
}

_cmux_start() {
  if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Usage: cmux start <branch>"
    echo ""
    echo "  Resume work in an existing worktree by launching Claude Code with --continue."
    return 0
  fi
  if [[ -z "$1" ]]; then
    echo "Usage: cmux start <branch>"
    return 1
  fi

  local branch="$1"
  local repo_root
  repo_root="$(_cmux_repo_root)" || { echo "Not in a git repo"; return 1; }

  local worktree_dir
  worktree_dir="$(_cmux_worktree_dir "$repo_root" "$branch")"

  if [[ ! -d "$worktree_dir" ]]; then
    echo "Worktree not found: $worktree_dir"
    echo "Run 'cmux ls' to see available worktrees, or 'cmux new $branch' to create one."
    return 1
  fi

  cd "$worktree_dir"
  claude -c
}

_cmux_cd() {
  if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Usage: cmux cd [branch]"
    echo ""
    echo "  cd into a worktree directory (no args = repo root)."
    return 0
  fi
  local repo_root
  repo_root="$(_cmux_repo_root)" || { echo "Not in a git repo"; return 1; }

  # No args: cd to repo root
  if [[ -z "$1" ]]; then
    cd "$repo_root"
    return
  fi

  local branch="$1"
  local worktree_dir
  worktree_dir="$(_cmux_worktree_dir "$repo_root" "$branch")"

  if [[ ! -d "$worktree_dir" ]]; then
    echo "Worktree not found: $worktree_dir"
    echo "Run 'cmux ls' to see available worktrees."
    return 1
  fi

  cd "$worktree_dir"
}

_cmux_ls() {
  if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Usage: cmux ls"
    echo ""
    echo "  List all cmux worktrees."
    return 0
  fi
  local repo_root
  repo_root="$(_cmux_repo_root)" || { echo "Not in a git repo"; return 1; }

  git -C "$repo_root" worktree list | grep '\.worktrees/'
}

_cmux_merge() {
  if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Usage: cmux merge [branch] [--squash]"
    echo ""
    echo "  Merge a worktree branch into the primary checkout."
    echo "  Run with no args from inside a .worktrees/ directory to auto-detect."
    return 0
  fi
  local branch=""
  local squash=false

  # Parse args
  for arg in "$@"; do
    case "$arg" in
      --squash) squash=true ;;
      *)        branch="$arg" ;;
    esac
  done

  local repo_root
  repo_root="$(_cmux_repo_root)" || { echo "Not in a git repo"; return 1; }

  # No branch arg: detect from current worktree
  if [[ -z "$branch" ]]; then
    if [[ "$PWD" == */.worktrees/* ]]; then
      local safe_name="${PWD##*/.worktrees/}"
      safe_name="${safe_name%%/*}"
      branch="$(git -C "$repo_root" worktree list --porcelain \
        | grep -A2 "$repo_root/.worktrees/$safe_name\$" \
        | grep '^branch ' \
        | sed 's|^branch refs/heads/||')"
      if [[ -z "$branch" ]]; then
        echo "Could not detect branch for current worktree."
        return 1
      fi
    else
      echo "Usage: cmux merge <branch> [--squash]"
      echo "  (or run with no args from inside a .worktrees/ directory)"
      return 1
    fi
  fi

  local worktree_dir
  worktree_dir="$(_cmux_worktree_dir "$repo_root" "$branch")"

  if [[ ! -d "$worktree_dir" ]]; then
    echo "Worktree not found: $worktree_dir"
    echo "Run 'cmux ls' to see available worktrees."
    return 1
  fi

  # Check for uncommitted changes in the worktree
  if ! git -C "$worktree_dir" diff --quiet 2>/dev/null || \
     ! git -C "$worktree_dir" diff --cached --quiet 2>/dev/null; then
    echo "Worktree has uncommitted changes: $worktree_dir"
    echo "Commit or stash them before merging."
    return 1
  fi

  # Determine what branch is checked out in the main repo
  local target_branch
  target_branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [[ -z "$target_branch" ]]; then
    echo "Could not determine branch in main checkout."
    return 1
  fi

  if [[ "$branch" == "$target_branch" ]]; then
    echo "Cannot merge '$branch' into itself."
    return 1
  fi

  # Move to repo root for the merge
  cd "$repo_root"

  echo "Merging '$branch' into '$target_branch'..."

  if [[ "$squash" == true ]]; then
    git merge --squash "$branch" || return 1
    echo ""
    echo "Squash merge staged. Review and commit the changes:"
    echo "  cd $repo_root && git commit"
  else
    git merge "$branch" || return 1
    echo "Merged '$branch' into '$target_branch'."
  fi
}

_cmux_rm() {
  if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Usage: cmux rm [branch]"
    echo "       cmux rm --all"
    echo ""
    echo "  Remove a worktree and its branch."
    echo "  Run with no args from inside a .worktrees/ directory to auto-detect."
    echo "  Use --all to remove all cmux worktrees (requires confirmation)."
    return 0
  fi
  local branch="$1"
  local repo_root
  repo_root="$(_cmux_repo_root)" || { echo "Not in a git repo"; return 1; }

  # --all: remove every cmux worktree
  if [[ "$branch" == "--all" ]]; then
    _cmux_rm_all "$repo_root"
    return $?
  fi

  # No args: detect current worktree
  if [[ -z "$branch" ]]; then
    if [[ "$PWD" == */.worktrees/* ]]; then
      local safe_name="${PWD##*/.worktrees/}"
      # Strip any trailing path components
      safe_name="${safe_name%%/*}"
      # We need to find the actual branch name from git worktree list
      branch="$(git -C "$repo_root" worktree list --porcelain \
        | grep -A2 "$repo_root/.worktrees/$safe_name\$" \
        | grep '^branch ' \
        | sed 's|^branch refs/heads/||')"
      if [[ -z "$branch" ]]; then
        echo "Could not detect branch for current worktree"
        return 1
      fi
      cd "$repo_root"
    else
      echo "Usage: cmux rm <branch>  (or run with no args from inside a .worktrees/ directory)"
      return 1
    fi
  fi

  local worktree_dir
  worktree_dir="$(_cmux_worktree_dir "$repo_root" "$branch")"

  if [[ ! -d "$worktree_dir" ]]; then
    echo "Worktree not found: $worktree_dir"
    return 1
  fi

  git -C "$repo_root" worktree remove "$worktree_dir" && \
    git -C "$repo_root" branch -d "$branch" 2>/dev/null

  echo "Removed worktree and branch: $branch"
}

_cmux_rm_all() {
  local repo_root="$1"
  local worktrees_dir="$repo_root/.worktrees"

  if [[ ! -d "$worktrees_dir" ]]; then
    echo "No .worktrees directory found."
    return 0
  fi

  # Collect worktree info: pairs of (directory, branch)
  local dirs=()
  local branches=()
  local wt_dir wt_branch
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    wt_dir="$(echo "$line" | awk '{print $1}')"
    wt_branch="$(git -C "$repo_root" worktree list --porcelain \
      | grep -A2 "^worktree ${wt_dir}\$" \
      | grep '^branch ' \
      | sed 's|^branch refs/heads/||')"
    dirs+=("$wt_dir")
    branches+=("${wt_branch:-unknown}")
  done < <(git -C "$repo_root" worktree list | grep '\.worktrees/')

  local count=${#dirs[@]}

  if [[ "$count" -eq 0 ]]; then
    echo "No cmux worktrees to remove."
    return 0
  fi

  # Show what will be removed
  echo "This will remove ALL cmux worktrees and their branches:"
  echo ""
  for (( i = 1; i <= ${#dirs[@]}; i++ )); do
    local rel_dir="${dirs[$i]#$repo_root/}"
    echo "  $rel_dir  (branch: ${branches[$i]})"
  done
  echo ""

  # Require exact confirmation string
  local expected="DELETE $count WORKTREES"
  printf 'Type "%s" to confirm: ' "$expected"
  read -r confirmation
  if [[ "$confirmation" != "$expected" ]]; then
    echo "Aborted."
    return 1
  fi

  # If user is inside a worktree, cd out first
  if [[ "$PWD" == "$worktrees_dir"* ]]; then
    cd "$repo_root"
  fi

  # Remove each worktree
  echo ""
  local failed=0
  for (( i = 1; i <= ${#dirs[@]}; i++ )); do
    if git -C "$repo_root" worktree remove --force "${dirs[$i]}" 2>/dev/null; then
      git -C "$repo_root" branch -d "${branches[$i]}" 2>/dev/null
      echo "  Removed: ${branches[$i]}"
    else
      echo "  Failed:  ${branches[$i]}"
      ((failed++))
    fi
  done

  echo ""
  if [[ "$failed" -eq 0 ]]; then
    echo "All $count worktrees removed."
  else
    echo "Done. $((count - failed))/$count removed ($failed failed)."
  fi
}

_cmux_init() {
  if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Usage: cmux init [--replace]"
    echo ""
    echo "  Generate a .cmux/setup hook using Claude Code."
    echo "  Use --replace to regenerate an existing setup hook."
    return 0
  fi
  local replace=false
  for arg in "$@"; do
    case "$arg" in
      --replace) replace=true ;;
    esac
  done

  local repo_root
  repo_root="$(_cmux_repo_root)" || { echo "Not in a git repo"; return 1; }

  if ! command -v claude &>/dev/null; then
    echo "claude CLI not found. Install it: https://docs.anthropic.com/en/docs/claude-code"
    return 1
  fi

  # Save into the current worktree if we're in one, otherwise repo root
  local target_dir
  target_dir="$(git rev-parse --show-toplevel 2>/dev/null)" || target_dir="$repo_root"
  local setup_file="$target_dir/.cmux/setup"

  if [[ -f "$setup_file" ]] && [[ "$replace" != true ]]; then
    echo ".cmux/setup already exists: $setup_file"
    echo "Run 'cmux init --replace' to regenerate it."
    return 1
  fi

  local tmpfile
  tmpfile="$(mktemp)" || { echo "Failed to create temp file"; return 1; }

  printf "Analyzing repo to generate .cmux/setup...  "
  mkdir -p "$target_dir/.cmux"

  local system_prompt
  system_prompt="$(cat <<'SYSPROMPT'
You generate bash scripts. Output ONLY the script itself — no markdown fences, no prose, no explanation. The first line of your response must be #!/bin/bash. Do not wrap the script in ``` code blocks.
SYSPROMPT
  )"

  local prompt
  prompt="$(cat <<'PROMPT'
Generate a .cmux/setup script for this repo. This script runs after a git worktree is created, from within the new worktree directory.

Rules:
- Start with #!/bin/bash
- Set REPO_ROOT="$(git rev-parse --git-common-dir | xargs dirname)"
- Symlink any gitignored secret/config files (e.g. .env, .env.local) from $REPO_ROOT
- Install dependencies if a lock file exists (detect package manager)
- Run codegen/build steps if applicable
- Only include steps relevant to THIS repo — omit anything that doesn't apply
- Use short bash comments for non-obvious lines
- No echo statements, no status messages, no decorative output
- If the repo needs no setup, output just: #!/bin/bash followed by a one-line comment explaining why

Example output for a Node.js project:

#!/bin/bash
REPO_ROOT="$(git rev-parse --git-common-dir | xargs dirname)"
ln -sf "$REPO_ROOT/.env" .env
ln -sf "$REPO_ROOT/.dev.vars" .dev.vars
npm ci && npx prisma generate

IMPORTANT: Output ONLY the raw bash script. The very first characters of your response must be #!/bin/bash — no preamble, no markdown, no commentary.
PROMPT
  )"

  local claude_pid
  _cmux_spinner_start
  [[ -n "$ZSH_VERSION" ]] && setopt localoptions nomonitor
  claude -p --system-prompt "$system_prompt" "$prompt" < /dev/null > "$tmpfile" 2>/dev/null &
  claude_pid=$!

  # Ctrl+C: kill claude, stop spinner, clean up
  trap 'kill $claude_pid 2>/dev/null; wait $claude_pid 2>/dev/null; _cmux_spinner_stop; rm -f "$tmpfile"; trap - INT; printf "\nAborted.\n"; return 130' INT

  local raw_output
  if ! wait "$claude_pid"; then
    _cmux_spinner_stop
    rm -f "$tmpfile"
    trap - INT
    echo "Failed to generate setup script"
    return 1
  fi
  _cmux_spinner_stop
  raw_output="$(<"$tmpfile")"
  rm -f "$tmpfile"

  local script
  if [[ "$raw_output" == *'#!/bin/bash'* ]]; then
    script="$raw_output"
  else
    trap - INT
    echo "Error: generated output did not contain a valid bash script."
    echo ""
    echo "Raw output:"
    echo "$raw_output"
    return 1
  fi

  # Show the generated script to the user
  echo ""
  echo "Generated .cmux/setup:"
  echo "────────────────────────────────"
  echo "$script"
  echo "────────────────────────────────"
  echo ""

  while true; do
    printf "  [enter] Accept   [e] Edit in \$EDITOR   [r] Regenerate   [q] Quit\n\n> "
    read -r choice
    case "$choice" in
      "")
        # Accept: write the script
        echo "$script" > "$setup_file"
        chmod +x "$setup_file"
        echo ""
        echo "Created $setup_file"
        echo "Tip: commit .cmux/setup to your repo so it's available in new worktrees."
        trap - INT
        return 0
        ;;
      e|E)
        # Write to temp file, open in editor, read back
        echo "$script" > "$setup_file"
        chmod +x "$setup_file"
        "${EDITOR:-vi}" "$setup_file"
        trap - INT
        if [[ -f "$setup_file" ]]; then
          echo ""
          echo "Saved $setup_file"
          echo "Tip: commit .cmux/setup to your repo so it's available in new worktrees."
          return 0
        else
          echo "File was removed during editing. Aborting."
          return 1
        fi
        ;;
      r|R)
        echo ""
        printf "Regenerating...  "
        tmpfile="$(mktemp)"
        _cmux_spinner_start
        [[ -n "$ZSH_VERSION" ]] && setopt localoptions nomonitor
        claude -p --system-prompt "$system_prompt" "$prompt" < /dev/null > "$tmpfile" 2>/dev/null &
        claude_pid=$!
        trap 'kill $claude_pid 2>/dev/null; wait $claude_pid 2>/dev/null; _cmux_spinner_stop; rm -f "$tmpfile"; trap - INT; printf "\nAborted.\n"; return 130' INT
        if ! wait "$claude_pid"; then
          _cmux_spinner_stop
          rm -f "$tmpfile"
          trap - INT
          echo "Failed to generate setup script"
          return 1
        fi
        _cmux_spinner_stop
        raw_output="$(<"$tmpfile")"
        rm -f "$tmpfile"
        if [[ "$raw_output" == *'#!/bin/bash'* ]]; then
          script="$raw_output"
        else
          trap - INT
          echo "Error: generated output did not contain a valid bash script."
          echo ""
          echo "Raw output:"
          echo "$raw_output"
          return 1
        fi
        echo ""
        echo "Generated .cmux/setup:"
        echo "────────────────────────────────"
        echo "$script"
        echo "────────────────────────────────"
        echo ""
        ;;
      q|Q)
        trap - INT
        echo "Aborted."
        return 1
        ;;
      *)
        echo "Invalid choice."
        ;;
    esac
  done
}

_cmux_update() {
  if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Usage: cmux update"
    echo ""
    echo "  Update cmux to the latest version."
    return 0
  fi
  local install_path="$HOME/.cmux/cmux.sh"

  echo "Checking for updates..."
  local remote_version
  remote_version="$(curl -fsSL "${_CMUX_DOWNLOAD_URL}/VERSION" 2>/dev/null | tr -d '[:space:]')"

  if [[ -z "$remote_version" ]]; then
    echo "Failed to check for updates (network error?)."
    return 1
  fi

  if [[ "$remote_version" == "$CMUX_VERSION" ]]; then
    echo "cmux is already up to date ($CMUX_VERSION)."
    return 0
  fi

  echo "Updating cmux ($CMUX_VERSION → $remote_version)..."
  if curl -fsSL "${_CMUX_DOWNLOAD_URL}/cmux.sh" -o "$install_path"; then
    printf '%s' "$remote_version" > "$HOME/.cmux/VERSION"
    printf '%s' "$remote_version" > "$HOME/.cmux/.latest_version"
    source "$install_path"
    echo "cmux updated to $CMUX_VERSION."
  else
    echo "Failed to download update."
    return 1
  fi
}

# ── Completions ──────────────────────────────────────────────────────

_cmux_worktree_names() {
  local repo_root
  repo_root="$(_cmux_repo_root 2>/dev/null)" || return
  git -C "$repo_root" worktree list --porcelain 2>/dev/null \
    | awk -v prefix="$repo_root/.worktrees/" '
        /^worktree / { wt=substr($0,10); in_wt=(index(wt,prefix)==1) }
        /^branch / && in_wt { sub(/^branch refs\/heads\//,""); print }'
}

if [[ -n "$ZSH_VERSION" ]]; then
  _cmux_zsh_complete() {
    local -a subcmds=(
      'new:New worktree + branch, launch Claude'
      'start:Continue where you left off'
      'cd:cd into worktree'
      'ls:List worktrees'
      'merge:Merge worktree branch into primary checkout'
      'rm:Remove worktree + branch'
      'init:Generate .cmux/setup hook'
      'update:Update cmux to latest version'
      'version:Show current version'
    )
    if (( CURRENT == 2 )); then
      _describe 'cmux command' subcmds
    elif (( CURRENT == 3 )); then
      case "${words[2]}" in
        start|cd|merge)
          local -a names=( ${(f)"$(_cmux_worktree_names)"} )
          compadd -a names
          ;;
        rm)
          local -a names=( ${(f)"$(_cmux_worktree_names)"} )
          compadd -a names
          compadd -- --all
          ;;
        init)
          compadd -- --replace
          ;;
      esac
    fi
  }
  compdef _cmux_zsh_complete cmux

elif [[ -n "$BASH_VERSION" ]]; then
  _cmux_bash_complete() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    if (( COMP_CWORD == 1 )); then
      COMPREPLY=( $(compgen -W "new start cd ls merge rm init update version" -- "$cur") )
    elif (( COMP_CWORD == 2 )); then
      case "$prev" in
        start|cd|merge)
          COMPREPLY=( $(compgen -W "$(_cmux_worktree_names)" -- "$cur") )
          ;;
        rm)
          COMPREPLY=( $(compgen -W "$(_cmux_worktree_names) --all" -- "$cur") )
          ;;
        init)
          COMPREPLY=( $(compgen -W "--replace" -- "$cur") )
          ;;
      esac
    fi
  }
  complete -F _cmux_bash_complete cmux
fi
