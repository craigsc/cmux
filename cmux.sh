# cmux — tmux for Claude Code
#
# Worktree lifecycle manager for parallel Claude Code sessions.
# Each agent gets its own worktree — no conflicts, one command each.
#
# Commands:
#   cmux new <branch> [-p <prompt>] [-- <claude-args>]   — New worktree + branch, run setup hook, launch Claude
#   cmux start <branch> [-p <prompt>] [-- <claude-args>] — Continue where you left off in an existing worktree
#   cmux cd [branch]      — cd into worktree (no args = repo root)
#   cmux ls               — List worktrees
#   cmux merge [branch]   — Merge worktree branch into primary checkout
#   cmux rm [branch]      — Remove worktree + branch, run teardown hook (no args = current, -f to force)
#   cmux rm --all         — Remove ALL worktrees, run teardown hooks (requires confirmation)
#   cmux init [--replace] — Generate .cmux/setup hook using Claude
#   cmux config           — View or set worktree layout configuration
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
    config)  _cmux_config "$@" ;;
    update)  _cmux_update "$@" ;;
    version) echo "cmux $CMUX_VERSION" ;;
    --help|-h|"")
      echo "Usage: cmux <new|start|cd|ls|merge|rm|init|config|update> [branch]"
      echo ""
      echo "  new <branch> [-p <prompt>] [-- <claude-args>]     New worktree + branch, run setup hook, launch Claude"
      echo "  start <branch> [-p <prompt>] [-- <claude-args>]   Continue where you left off in an existing worktree"
      echo "  cd [branch]      cd into worktree (no args = repo root)"
      echo "  ls               List worktrees"
      echo "  merge [branch]   Merge worktree branch into primary checkout"
      echo "  rm [branch]      Remove worktree + branch (no args = current, -f to force)"
      echo "  rm --all         Remove ALL worktrees (requires confirmation)"
      echo "  init [--replace] Generate .cmux/setup hook using Claude"
      echo "  config           View or set worktree layout configuration"
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
# Uses realpath instead of cd to avoid triggering direnv/shell hooks
_cmux_repo_root() {
  local git_common_dir
  git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  # --git-common-dir returns the .git dir; parent is repo root
  realpath "$(dirname "$git_common_dir")"
}

# Sanitize branch name: slashes become hyphens
_cmux_safe_name() {
  echo "${1//\//-}"
}

# Read layout config: per-project > global > default (nested)
_cmux_get_layout() {
  local repo_root="$1"
  local layout=""
  # Per-project config
  if [[ -n "$repo_root" && -f "$repo_root/.cmux/config.json" ]]; then
    layout="$(grep '"layout"' "$repo_root/.cmux/config.json" 2>/dev/null | sed 's/.*"layout"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
  fi
  # Global config fallback
  if [[ -z "$layout" && -f "$HOME/.cmux/config.json" ]]; then
    layout="$(grep '"layout"' "$HOME/.cmux/config.json" 2>/dev/null | sed 's/.*"layout"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
  fi
  # Default
  echo "${layout:-nested}"
}

# Return the base directory that contains worktrees
_cmux_worktree_base() {
  local repo_root="$1"
  local layout
  layout="$(_cmux_get_layout "$repo_root")"
  case "$layout" in
    outer-nested) echo "$(dirname "$repo_root")/$(basename "$repo_root").worktrees" ;;
    sibling)      echo "$(dirname "$repo_root")" ;;
    *)            echo "$repo_root/.worktrees" ;;
  esac
}

# Resolve worktree directory for a branch
_cmux_worktree_dir() {
  local repo_root="$1"
  local safe_name="$(_cmux_safe_name "$2")"
  local layout
  layout="$(_cmux_get_layout "$repo_root")"
  case "$layout" in
    outer-nested) echo "$(dirname "$repo_root")/$(basename "$repo_root").worktrees/$safe_name" ;;
    sibling)      echo "$(dirname "$repo_root")/$(basename "$repo_root")-$safe_name" ;;
    *)            echo "$repo_root/.worktrees/$safe_name" ;;
  esac
}

# Detect branch name from current worktree directory
_cmux_detect_worktree_branch() {
  local repo_root="$1"
  local layout
  layout="$(_cmux_get_layout "$repo_root")"
  local base safe_name wt_dir

  case "$layout" in
    outer-nested)
      base="$(dirname "$repo_root")/$(basename "$repo_root").worktrees"
      if [[ "$PWD" == "$base/"* ]]; then
        safe_name="${PWD#$base/}"
        safe_name="${safe_name%%/*}"
        wt_dir="$base/$safe_name"
      fi
      ;;
    sibling)
      local repo_name
      repo_name="$(basename "$repo_root")"
      local parent
      parent="$(dirname "$repo_root")"
      local current_dir
      current_dir="$(basename "$PWD")"
      # Strip subdirs: get the top-level sibling dir
      local check_dir="$PWD"
      while [[ "$(dirname "$check_dir")" != "$parent" && "$check_dir" != "/" ]]; do
        check_dir="$(dirname "$check_dir")"
      done
      current_dir="$(basename "$check_dir")"
      if [[ "$current_dir" == "${repo_name}-"* && "$check_dir" != "$repo_root" ]]; then
        safe_name="${current_dir#${repo_name}-}"
        wt_dir="$parent/$current_dir"
      fi
      ;;
    *)  # nested
      if [[ "$PWD" == */.worktrees/* ]]; then
        safe_name="${PWD##*/.worktrees/}"
        safe_name="${safe_name%%/*}"
        wt_dir="$repo_root/.worktrees/$safe_name"
      fi
      ;;
  esac

  [[ -z "$safe_name" ]] && return 1

  # Resolve actual branch name from git worktree list
  git -C "$repo_root" worktree list --porcelain \
    | grep -A2 "^worktree ${wt_dir}\$" \
    | grep '^branch ' \
    | sed 's|^branch refs/heads/||'
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
    echo "Usage: cmux new <branch> [-p <prompt>] [-- <claude-args>]"
    echo ""
    echo "  Create a new worktree and branch, run setup hook, and launch Claude Code."
    echo "  Use -p to pass an initial prompt to Claude."
    echo "  Use -- to pass additional flags to the claude CLI."
    return 0
  fi
  if [[ -z "$1" ]]; then
    echo "Usage: cmux new <branch> [-p <prompt>] [-- <claude-args>]"
    return 1
  fi

  local prompt=""
  local branch_words=()
  local claude_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p) prompt="$2"; shift 2 ;;
      --) shift; claude_args=("$@"); break ;;
      *)  branch_words+=("$1"); shift ;;
    esac
  done
  local branch="${branch_words[*]// /-}"

  if [[ -z "$branch" ]]; then
    echo "Usage: cmux new <branch> [-p <prompt>] [-- <claude-args>]"
    return 1
  fi
  local repo_root
  repo_root="$(_cmux_repo_root)" || { echo "Not in a git repo"; return 1; }

  local worktree_dir
  worktree_dir="$(_cmux_worktree_dir "$repo_root" "$branch")"

  # Idempotent: if worktree already exists, just cd there
  if [[ -d "$worktree_dir" ]]; then
    echo "Worktree already exists: $worktree_dir"
    cd "$worktree_dir"
  else
    # Ensure worktree base directory exists
    local base_dir
    base_dir="$(_cmux_worktree_base "$repo_root")"
    local layout
    layout="$(_cmux_get_layout "$repo_root")"
    if [[ "$layout" != "sibling" ]]; then
      mkdir -p "$base_dir"
    fi
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
  if [[ -n "$prompt" ]]; then
    claude "${claude_args[@]}" "$prompt"
  else
    claude "${claude_args[@]}"
  fi
}

_cmux_start() {
  if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Usage: cmux start <branch> [-p <prompt>] [-- <claude-args>]"
    echo ""
    echo "  Resume work in an existing worktree by launching Claude Code with --continue."
    echo "  Use -p to pass an initial prompt to Claude."
    echo "  Use -- to pass additional flags to the claude CLI."
    return 0
  fi
  if [[ -z "$1" ]]; then
    echo "Usage: cmux start <branch> [-p <prompt>] [-- <claude-args>]"
    return 1
  fi

  local prompt=""
  local branch=""
  local claude_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p) prompt="$2"; shift 2 ;;
      --) shift; claude_args=("$@"); break ;;
      *)  branch="$1"; shift ;;
    esac
  done

  if [[ -z "$branch" ]]; then
    echo "Usage: cmux start <branch> [-p <prompt>] [-- <claude-args>]"
    return 1
  fi
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
  if [[ -n "$prompt" ]]; then
    claude "${claude_args[@]}" -c "$prompt"
  else
    claude "${claude_args[@]}" -c
  fi
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

  local layout
  layout="$(_cmux_get_layout "$repo_root")"
  local filter
  case "$layout" in
    outer-nested) filter="$(dirname "$repo_root")/$(basename "$repo_root").worktrees/" ;;
    sibling)      filter="$(dirname "$repo_root")/$(basename "$repo_root")-" ;;
    *)            filter="$(_cmux_worktree_base "$repo_root")/" ;;
  esac
  git -C "$repo_root" worktree list | grep -F "$filter"
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
    branch="$(_cmux_detect_worktree_branch "$repo_root")"
    if [[ -z "$branch" ]]; then
      echo "Usage: cmux merge <branch> [--squash]"
      echo "  (or run with no args from inside a worktree directory)"
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
    echo "Usage: cmux rm [branch] [-f|--force]"
    echo "       cmux rm --all"
    echo ""
    echo "  Remove a worktree and its branch."
    echo "  Run with no args from inside a .worktrees/ directory to auto-detect."
    echo "  Use -f/--force to remove a worktree with uncommitted changes."
    echo "  Use --all to remove all cmux worktrees (requires confirmation)."
    return 0
  fi
  local force=false
  local branch=""
  local arg
  for arg in "$@"; do
    case "$arg" in
      --force|-f) force=true ;;
      --all)      branch="--all" ;;
      *)          branch="$arg" ;;
    esac
  done

  local repo_root
  repo_root="$(_cmux_repo_root)" || { echo "Not in a git repo"; return 1; }

  # --all: remove every cmux worktree
  if [[ "$branch" == "--all" ]]; then
    _cmux_rm_all "$repo_root"
    return $?
  fi

  # No args: detect current worktree
  if [[ -z "$branch" ]]; then
    branch="$(_cmux_detect_worktree_branch "$repo_root")"
    if [[ -z "$branch" ]]; then
      echo "Usage: cmux rm <branch>  (or run with no args from inside a worktree directory)"
      return 1
    fi
    cd "$repo_root"
  fi

  local worktree_dir
  worktree_dir="$(_cmux_worktree_dir "$repo_root" "$branch")"

  if [[ ! -d "$worktree_dir" ]]; then
    echo "Worktree not found: $worktree_dir"
    return 1
  fi

  local remove_args=("$worktree_dir")
  if $force; then
    remove_args=("--force" "${remove_args[@]}")
  fi

  # Run project-specific teardown hook before removal
  cd "$worktree_dir"
  if [[ -x "$worktree_dir/.cmux/teardown" ]]; then
    echo "Running .cmux/teardown..."
    "$worktree_dir/.cmux/teardown"
  elif [[ -x "$repo_root/.cmux/teardown" ]]; then
    echo "Running .cmux/teardown from repo root..."
    "$repo_root/.cmux/teardown"
  fi

  if git -C "$repo_root" worktree remove "${remove_args[@]}"; then
    git -C "$repo_root" branch -d "$branch" 2>/dev/null
    # If we were inside the removed worktree, cd out
    if [[ "$PWD" == "$worktree_dir"* ]]; then
      cd "$repo_root"
    fi
    echo "Removed worktree and branch: $branch"
  else
    echo "Failed to remove worktree: $branch"
    if ! $force; then
      echo "Hint: use 'cmux rm --force $branch' to remove a worktree with uncommitted changes"
    fi
    return 1
  fi
}

_cmux_rm_all() {
  local repo_root="$1"
  local base_dir
  base_dir="$(_cmux_worktree_base "$repo_root")"
  local layout
  layout="$(_cmux_get_layout "$repo_root")"

  if [[ "$layout" != "sibling" && ! -d "$base_dir" ]]; then
    echo "No worktrees directory found."
    return 0
  fi

  # Build filter pattern for finding cmux worktrees
  local filter
  case "$layout" in
    outer-nested) filter="$(dirname "$repo_root")/$(basename "$repo_root").worktrees/" ;;
    sibling)      filter="$(dirname "$repo_root")/$(basename "$repo_root")-" ;;
    *)            filter="$base_dir/" ;;
  esac

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
  done < <(git -C "$repo_root" worktree list | grep -F "$filter")

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
  if _cmux_detect_worktree_branch "$repo_root" &>/dev/null; then
    cd "$repo_root"
  fi

  # Remove each worktree
  echo ""
  local failed=0
  for (( i = 1; i <= ${#dirs[@]}; i++ )); do
    # Run project-specific teardown hook
    cd "${dirs[$i]}"
    if [[ -x "${dirs[$i]}/.cmux/teardown" ]]; then
      "${dirs[$i]}/.cmux/teardown"
    elif [[ -x "$repo_root/.cmux/teardown" ]]; then
      "$repo_root/.cmux/teardown"
    fi
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
  IFS= read -r -d '' system_prompt <<'SYSPROMPT' || true
You generate bash scripts. Output ONLY the script itself — no markdown fences, no prose, no explanation. The first line of your response must be #!/bin/bash. Do not wrap the script in ``` code blocks.
SYSPROMPT

  local prompt
  IFS= read -r -d '' prompt <<'PROMPT' || true
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

_cmux_config() {
  local repo_root
  repo_root="$(_cmux_repo_root 2>/dev/null)"

  # No args: show effective layout
  if [[ -z "$1" ]]; then
    local layout source
    if [[ -n "$repo_root" && -f "$repo_root/.cmux/config.json" ]] \
       && grep -q '"layout"' "$repo_root/.cmux/config.json" 2>/dev/null; then
      layout="$(grep '"layout"' "$repo_root/.cmux/config.json" | sed 's/.*"layout"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
      source="$repo_root/.cmux/config.json"
    elif [[ -f "$HOME/.cmux/config.json" ]] \
       && grep -q '"layout"' "$HOME/.cmux/config.json" 2>/dev/null; then
      layout="$(grep '"layout"' "$HOME/.cmux/config.json" | sed 's/.*"layout"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
      source="~/.cmux/config.json"
    else
      layout="nested"
      source="default"
    fi
    echo "layout=$layout (source: $source)"
    return 0
  fi

  if [[ "$1" != "set" ]]; then
    echo "Usage: cmux config                               Show effective layout"
    echo "       cmux config set layout <preset>            Set per-project"
    echo "       cmux config set layout <preset> --global   Set global default"
    echo ""
    echo "Presets: nested, outer-nested, sibling"
    return 1
  fi
  shift

  local global=false
  local key="" preset=""
  for arg in "$@"; do
    case "$arg" in
      --global) global=true ;;
      layout)   key="layout" ;;
      *)        preset="$arg" ;;
    esac
  done

  if [[ "$key" != "layout" || -z "$preset" ]]; then
    echo "Usage: cmux config set layout <preset> [--global]"
    return 1
  fi
  case "$preset" in
    nested|outer-nested|sibling) ;;
    *)
      echo "Invalid layout: $preset"
      echo "Valid presets: nested, outer-nested, sibling"
      return 1
      ;;
  esac

  local config_file
  if [[ "$global" == true ]]; then
    config_file="$HOME/.cmux/config.json"
  else
    if [[ -z "$repo_root" ]]; then
      echo "Not in a git repo. Use --global to set globally."
      return 1
    fi
    config_file="$repo_root/.cmux/config.json"
    mkdir -p "$repo_root/.cmux"
  fi

  # Warn if worktrees exist
  if [[ -n "$repo_root" ]]; then
    local base_dir
    base_dir="$(_cmux_worktree_base "$repo_root")"
    local existing
    existing="$(git -C "$repo_root" worktree list 2>/dev/null | grep -F "$base_dir/" | wc -l | tr -d ' ')"
    if [[ "$existing" -gt 0 ]]; then
      echo "Warning: $existing existing worktrees use the current layout."
      echo "Changing layout won't move them. Remove them first with 'cmux rm --all'."
    fi
  fi

  # Write config as JSON
  if [[ -f "$config_file" ]] && grep -q '"layout"' "$config_file" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    sed 's/"layout"[[:space:]]*:[[:space:]]*"[^"]*"/"layout": "'"$preset"'"/' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
  else
    printf '{\n  "layout": "%s"\n}\n' "$preset" > "$config_file"
  fi

  local target="per-project"
  [[ "$global" == true ]] && target="global"
  echo "Set $target layout to: $preset"
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
  local layout
  layout="$(_cmux_get_layout "$repo_root")"
  local prefix
  case "$layout" in
    outer-nested) prefix="$(dirname "$repo_root")/$(basename "$repo_root").worktrees/" ;;
    sibling)      prefix="$(dirname "$repo_root")/$(basename "$repo_root")-" ;;
    *)            prefix="$(_cmux_worktree_base "$repo_root")/" ;;
  esac
  git -C "$repo_root" worktree list --porcelain 2>/dev/null \
    | awk -v prefix="$prefix" '
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
      'config:View or set configuration'
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
        config)
          compadd -- set
          ;;
      esac
    elif (( CURRENT == 4 )); then
      case "${words[2]}" in
        config)
          if [[ "${words[3]}" == "set" ]]; then
            compadd -- layout
          fi
          ;;
      esac
    elif (( CURRENT == 5 )); then
      case "${words[2]}" in
        config)
          if [[ "${words[3]}" == "set" && "${words[4]}" == "layout" ]]; then
            compadd -- nested outer-nested sibling
          fi
          ;;
      esac
    elif (( CURRENT == 6 )); then
      case "${words[2]}" in
        config)
          if [[ "${words[3]}" == "set" && "${words[4]}" == "layout" ]]; then
            compadd -- --global
          fi
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
      COMPREPLY=( $(compgen -W "new start cd ls merge rm init config update version" -- "$cur") )
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
        config)
          COMPREPLY=( $(compgen -W "set" -- "$cur") )
          ;;
      esac
    elif (( COMP_CWORD == 3 )); then
      if [[ "${COMP_WORDS[1]}" == "config" && "${COMP_WORDS[2]}" == "set" ]]; then
        COMPREPLY=( $(compgen -W "layout" -- "$cur") )
      fi
    elif (( COMP_CWORD == 4 )); then
      if [[ "${COMP_WORDS[1]}" == "config" && "${COMP_WORDS[2]}" == "set" \
         && "${COMP_WORDS[3]}" == "layout" ]]; then
        COMPREPLY=( $(compgen -W "nested outer-nested sibling" -- "$cur") )
      fi
    elif (( COMP_CWORD == 5 )); then
      if [[ "${COMP_WORDS[1]}" == "config" && "${COMP_WORDS[2]}" == "set" \
         && "${COMP_WORDS[3]}" == "layout" ]]; then
        COMPREPLY=( $(compgen -W "--global" -- "$cur") )
      fi
    fi
  }
  complete -F _cmux_bash_complete cmux
fi
