#!/usr/bin/env bash
set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# --- Configuration ---

DEFAULT_PROTECTED_BRANCHES='["main","master"]'
DEFAULT_RULES='{
  "no-amend": true,
  "no-commit-on-protected": true,
  "no-push-to-protected": true,
  "no-force-push": true,
  "no-reset-hard": true,
  "no-discard-all": true,
  "no-rebase-on-protected": true,
  "require-git-repo": false
}'

# Load project config if present
CONFIG_FILE="${CWD:-.}/.claude/git-governor.json"
if [[ -f "$CONFIG_FILE" ]]; then
  PROTECTED_BRANCHES=$(jq -c '.["protected-branches"] // '"$DEFAULT_PROTECTED_BRANCHES" "$CONFIG_FILE")
  rule_enabled() {
    local val
    val=$(jq -r ".rules[\"$1\"] // null" "$CONFIG_FILE")
    if [[ "$val" == "null" ]]; then
      echo "$DEFAULT_RULES" | jq -r ".[\"$1\"]"
    else
      echo "$val"
    fi
  }
else
  PROTECTED_BRANCHES="$DEFAULT_PROTECTED_BRANCHES"
  rule_enabled() {
    echo "$DEFAULT_RULES" | jq -r ".[\"$1\"]"
  }
fi

# Convert protected branches JSON array to a bash-friendly check
is_protected() {
  local branch="$1"
  echo "$PROTECTED_BRANCHES" | jq -e --arg b "$branch" 'map(. as $pat |
    if ($pat | contains("*"))
    then ($b | test("^" + ($pat | gsub("\\*"; ".*")) + "$"))
    else $b == $pat
    end
  ) | any' > /dev/null 2>&1
}

current_branch() {
  git -C "${CWD:-.}" branch --show-current 2>/dev/null || echo ""
}

block() {
  jq -n --arg reason "$1" '{"decision":"block","reason":$reason}'
  exit 2
}

# --- Write|Edit rules ---

if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
  # 8. Require git repo for file edits (opt-in)
  if [[ "$(rule_enabled require-git-repo)" == "true" ]] && [[ -n "$FILE_PATH" ]]; then
    FILE_DIR=$(dirname "$FILE_PATH")
    if ! git -C "$FILE_DIR" rev-parse --git-dir > /dev/null 2>&1; then
      # Check for opt-out in CLAUDE.md (search upward)
      CHECK_DIR="$FILE_DIR"
      OPTED_OUT=false
      while [[ "$CHECK_DIR" != "/" ]]; do
        for candidate in "$CHECK_DIR/CLAUDE.md" "$CHECK_DIR/.claude/CLAUDE.md"; do
          if [[ -f "$candidate" ]] && grep -qi "no.* git\|not use git\|without git\|git.*disabled\|skip.*git" "$candidate" 2>/dev/null; then
            OPTED_OUT=true
            break 2
          fi
        done
        CHECK_DIR=$(dirname "$CHECK_DIR")
      done
      if [[ "$OPTED_OUT" == "false" ]]; then
        block "No git repository found for ${FILE_PATH}. Initialize a git repo, or add a git opt-out note to CLAUDE.md."
      fi
    fi
  fi
  exit 0
fi

# --- Bash rules ---

# No command or not a git command — allow
if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# Quick check: does this command involve git at all?
if ! echo "$COMMAND" | grep -qE '\bgit\b'; then
  exit 0
fi

# 1. No amend
if [[ "$(rule_enabled no-amend)" == "true" ]]; then
  if echo "$COMMAND" | grep -qE '\bgit\s+commit\b.*--amend\b'; then
    block "git commit --amend is blocked. Create a new commit instead."
  fi
fi

# 2. No force push (check before push-to-protected since it's more specific)
if [[ "$(rule_enabled no-force-push)" == "true" ]]; then
  if echo "$COMMAND" | grep -qE '\bgit\s+push\b.*(\s-f\b|\s--force\b|\s--force-with-lease\b)'; then
    block "Force push is blocked. Push normally or create a new branch."
  fi
  # +refspec syntax: git push origin +branch
  if echo "$COMMAND" | grep -qE '\bgit\s+push\b.*\s\+\w'; then
    block "Force push via +refspec is blocked. Push normally or create a new branch."
  fi
fi

# 3. No push to protected branch
if [[ "$(rule_enabled no-push-to-protected)" == "true" ]]; then
  if echo "$COMMAND" | grep -qE '\bgit\s+push\b'; then
    # Check for explicit branch name in command
    for branch in $(echo "$PROTECTED_BRANCHES" | jq -r '.[]'); do
      # Match: git push origin main, git push origin main:main, etc.
      if echo "$COMMAND" | grep -qE "\bgit\s+push\b.*\b${branch}\b"; then
        block "Pushing to protected branch '${branch}' is blocked."
      fi
    done
    # Bare "git push" while on a protected branch
    if echo "$COMMAND" | grep -qE '\bgit\s+push\s*$' || echo "$COMMAND" | grep -qE '\bgit\s+push\s+(origin|upstream)\s*$'; then
      BRANCH=$(current_branch)
      if [[ -n "$BRANCH" ]] && is_protected "$BRANCH"; then
        block "Pushing to protected branch '${BRANCH}' is blocked (you're on it)."
      fi
    fi
  fi
fi

# 4. No commit on protected branch
if [[ "$(rule_enabled no-commit-on-protected)" == "true" ]]; then
  if echo "$COMMAND" | grep -qE '\bgit\s+commit\b'; then
    BRANCH=$(current_branch)
    if [[ -n "$BRANCH" ]] && is_protected "$BRANCH"; then
      block "Committing directly to protected branch '${BRANCH}' is blocked. Create a feature branch first."
    fi
  fi
fi

# 5. No reset --hard
if [[ "$(rule_enabled no-reset-hard)" == "true" ]]; then
  if echo "$COMMAND" | grep -qE '\bgit\s+reset\b.*--hard\b'; then
    block "git reset --hard is blocked. Use git stash or git reset --soft instead."
  fi
fi

# 6. No discard all changes
if [[ "$(rule_enabled no-discard-all)" == "true" ]]; then
  # git checkout . / git checkout -- .
  if echo "$COMMAND" | grep -qE '\bgit\s+checkout\s+(--\s+)?\.(\s|$)'; then
    block "git checkout . is blocked (discards all changes). Stage and commit your work, or use git stash."
  fi
  # git restore .
  if echo "$COMMAND" | grep -qE '\bgit\s+restore\s+\.(\s|$)'; then
    block "git restore . is blocked (discards all changes). Stage and commit your work, or use git stash."
  fi
  # git clean -f / git clean -fd
  if echo "$COMMAND" | grep -qE '\bgit\s+clean\b.*-[a-zA-Z]*f'; then
    block "git clean -f is blocked (deletes untracked files). Review files manually first."
  fi
fi

# 7. No rebase on protected branch
if [[ "$(rule_enabled no-rebase-on-protected)" == "true" ]]; then
  if echo "$COMMAND" | grep -qE '\bgit\s+rebase\b'; then
    BRANCH=$(current_branch)
    if [[ -n "$BRANCH" ]] && is_protected "$BRANCH"; then
      block "Rebasing while on protected branch '${BRANCH}' is blocked. Switch to a feature branch first."
    fi
  fi
fi

# All checks passed
exit 0
