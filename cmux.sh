# cmux — Claude Multiplexer
#
# Worktree lifecycle manager for parallel Claude Code sessions.
# Generic core with project-specific setup via .cmux/setup hook.
#
# Commands:
#   cmux new <branch>     — Create worktree, run setup hook, launch claude
#   cmux start <branch>   — Launch claude -c in an existing worktree
#   cmux cd [branch]      — cd into worktree (no args = repo root)
#   cmux ls               — List worktrees
#   cmux merge [branch]   — Merge worktree branch into main checkout
#   cmux rm [branch]      — Remove worktree (no args = current worktree)
#   cmux rm --all         — Remove ALL worktrees (requires confirmation)
#   cmux init             — Generate .cmux/setup hook using Claude

cmux() {
  local cmd="$1"
  shift 2>/dev/null

  case "$cmd" in
    new)   _cmux_new "$@" ;;
    start) _cmux_start "$@" ;;
    cd)    _cmux_cd "$@" ;;
    ls)    _cmux_ls "$@" ;;
    merge) _cmux_merge "$@" ;;
    rm)    _cmux_rm "$@" ;;
    init)  _cmux_init "$@" ;;
    *)
      echo "Usage: cmux <new|start|cd|ls|merge|rm|init> [branch]"
      echo ""
      echo "  new <branch>     Create worktree, run setup hook, launch claude"
      echo "  start <branch>   Launch claude -c in existing worktree"
      echo "  cd [branch]      cd into worktree (no args = repo root)"
      echo "  ls               List worktrees"
      echo "  merge [branch]   Merge worktree branch into main checkout"
      echo "  rm [branch]      Remove worktree (no args = current)"
      echo "  rm --all         Remove ALL worktrees (requires confirmation)"
      echo "  init             Generate .cmux/setup hook using Claude"
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

# ── Subcommands ──────────────────────────────────────────────────────

_cmux_new() {
  if [[ -z "$1" ]]; then
    echo "Usage: cmux new <branch>"
    return 1
  fi

  local branch="$1"
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
  local repo_root
  repo_root="$(_cmux_repo_root)" || { echo "Not in a git repo"; return 1; }

  git -C "$repo_root" worktree list | grep '\.worktrees/'
}

_cmux_merge() {
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
  local repo_root
  repo_root="$(_cmux_repo_root)" || { echo "Not in a git repo"; return 1; }

  if ! command -v claude &>/dev/null; then
    echo "claude CLI not found. Install it: https://docs.anthropic.com/en/docs/claude-code"
    return 1
  fi

  local setup_file="$repo_root/.cmux/setup"

  if [[ -f "$setup_file" ]]; then
    echo ".cmux/setup already exists: $setup_file"
    return 1
  fi

  echo "Analyzing repo to generate .cmux/setup..."
  mkdir -p "$repo_root/.cmux"

  local prompt
  prompt="$(cat <<'PROMPT'
You are generating a .cmux/setup script for a git worktree manager. Analyze this repository and output ONLY an executable bash script — no markdown fences, no commentary, no explanation. Your entire response must be valid bash. The very first line of your response must be #!/bin/bash — do not output anything before it.

The script runs inside a freshly created git worktree. It should:
1. Start with #!/bin/bash
2. Set REPO_ROOT using: REPO_ROOT="$(git rev-parse --git-common-dir | xargs dirname)"
3. Symlink any secret/config files from REPO_ROOT that are gitignored (e.g. .env, .env.local)
4. Install dependencies (detect the package manager from lock files)
5. Run any necessary codegen or build steps

Only include steps that are relevant to this specific repo. Keep it minimal and correct.
PROMPT
  )"

  local raw_output
  if ! raw_output="$(claude -p "$prompt")"; then
    echo "Failed to generate setup script"
    return 1
  fi

  # Extract only the bash script (from #!/bin/bash onward) in case
  # the model included any prose before the script
  local script
  if [[ "$raw_output" == *'#!/bin/bash'* ]]; then
    script="$(echo "$raw_output" | sed -n '/^#!\/bin\/bash/,$p')"
  else
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
        return 0
        ;;
      e|E)
        # Write to temp file, open in editor, read back
        echo "$script" > "$setup_file"
        chmod +x "$setup_file"
        "${EDITOR:-vi}" "$setup_file"
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
        echo "Regenerating..."
        if ! raw_output="$(claude -p "$prompt")"; then
          echo "Failed to generate setup script"
          return 1
        fi
        if [[ "$raw_output" == *'#!/bin/bash'* ]]; then
          script="$(echo "$raw_output" | sed -n '/^#!\/bin\/bash/,$p')"
        else
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
        echo "Aborted."
        return 1
        ;;
      *)
        echo "Invalid choice."
        ;;
    esac
  done
}
