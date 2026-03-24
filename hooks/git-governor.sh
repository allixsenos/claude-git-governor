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
  "no-amend": "deny",
  "no-commit-on-protected": "deny",
  "no-push-to-protected": "ask",
  "no-force-push": "deny",
  "no-reset-hard": "deny",
  "no-discard-all": "deny",
  "no-rebase-on-protected": "deny",
  "no-add-all": "deny",
  "no-merge-pr": "ask",
  "require-git-repo": "allow"
}'

# Load config: project > global > defaults
PROJECT_CONFIG="${CWD:-.}/.claude/git-governor.json"
GLOBAL_CONFIG="${HOME}/.claude/git-governor.json"

# Protected branches: first config that defines them wins
if [[ -f "$PROJECT_CONFIG" ]] && jq -e '.["protected-branches"]' "$PROJECT_CONFIG" > /dev/null 2>&1; then
  PROTECTED_BRANCHES=$(jq -c '.["protected-branches"]' "$PROJECT_CONFIG")
elif [[ -f "$GLOBAL_CONFIG" ]] && jq -e '.["protected-branches"]' "$GLOBAL_CONFIG" > /dev/null 2>&1; then
  PROTECTED_BRANCHES=$(jq -c '.["protected-branches"]' "$GLOBAL_CONFIG")
else
  PROTECTED_BRANCHES="$DEFAULT_PROTECTED_BRANCHES"
fi

# Rule mode: project > global > default
rule_mode() {
  local val
  if [[ -f "$PROJECT_CONFIG" ]] && jq -e ".rules | has(\"$1\")" "$PROJECT_CONFIG" > /dev/null 2>&1; then
    val=$(jq -r ".rules[\"$1\"]" "$PROJECT_CONFIG")
  elif [[ -f "$GLOBAL_CONFIG" ]] && jq -e ".rules | has(\"$1\")" "$GLOBAL_CONFIG" > /dev/null 2>&1; then
    val=$(jq -r ".rules[\"$1\"]" "$GLOBAL_CONFIG")
  else
    val=$(echo "$DEFAULT_RULES" | jq -r ".[\"$1\"]")
  fi
  echo "$val"
}

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

deny() {
  jq -n --arg reason "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
}

ask() {
  jq -n --arg reason "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$reason}}'
  exit 0
}

# Enforce a rule: "deny" → block, "ask" → prompt user, "allow" → skip
enforce() {
  local mode="$1" reason="$2"
  case "$mode" in
    deny) deny "$reason" ;;
    ask)  ask "$reason" ;;
    allow) return ;;
    *) deny "Invalid rule mode '${mode}'. Valid values: deny, ask, allow." ;;
  esac
}

# Check if a rule is active (not "allow")
rule_active() {
  local mode="$1"
  [[ "$mode" != "allow" ]]
}

# --- Write|Edit rules ---

if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
  # Require git repo for file edits (opt-in)
  MODE=$(rule_mode require-git-repo)
  if rule_active "$MODE" && [[ -n "$FILE_PATH" ]]; then
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
        enforce "$MODE" "No git repository found for ${FILE_PATH}. Initialize a git repo, or add a git opt-out note to CLAUDE.md."
      fi
    fi
  fi
  exit 0
fi

# --- Bash rules ---

# No command — allow
if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# Sanitize command: strip heredoc content and quoted strings to prevent
# false positives from git-related text inside arguments (fixes #16).
SCAN="$COMMAND"
if printf '%s' "$SCAN" | grep -q '<<'; then
  SCAN=$(printf '%s' "$SCAN" | perl -0777 -pe "s/<<~?'?(\w+)'?\s*\n.*?\n\1\b//gs" 2>/dev/null) || SCAN="$COMMAND"
fi
SCAN=$(printf '%s' "$SCAN" | sed "s/'[^']*'//g" | sed 's/"[^"]*"//g')

# Quick check: does the sanitized command invoke git or gh?
if ! printf '%s' "$SCAN" | grep -qE '\b(git|gh)\b'; then
  exit 0
fi

# 1. No amend
MODE=$(rule_mode no-amend)
if rule_active "$MODE"; then
  if printf '%s' "$SCAN" | grep -qE '\bgit\s+commit\b.*--amend\b'; then
    enforce "$MODE" "git commit --amend is blocked. Create a new commit instead."
  fi
fi

# 2. No force push (check before push-to-protected since it's more specific)
MODE=$(rule_mode no-force-push)
if rule_active "$MODE"; then
  if printf '%s' "$SCAN" | grep -qE '\bgit\s+push\b.*(\s-f\b|\s--force\b|\s--force-with-lease\b)'; then
    enforce "$MODE" "Force push is blocked. Push normally or create a new branch."
  fi
  # +refspec syntax: git push origin +branch
  if printf '%s' "$SCAN" | grep -qE '\bgit\s+push\b.*\s\+\w'; then
    enforce "$MODE" "Force push via +refspec is blocked. Push normally or create a new branch."
  fi
fi

# 3. No push to protected branch
MODE=$(rule_mode no-push-to-protected)
if rule_active "$MODE"; then
  if printf '%s' "$SCAN" | grep -qE '\bgit\s+push\b'; then
    # Check for explicit branch name in command
    for branch in $(echo "$PROTECTED_BRANCHES" | jq -r '.[]'); do
      if printf '%s' "$SCAN" | grep -qE "\bgit\s+push\b.*\b${branch}\b"; then
        enforce "$MODE" "Pushing to protected branch '${branch}' is blocked."
      fi
    done
    # Bare "git push" while on a protected branch
    if printf '%s' "$SCAN" | grep -qE '\bgit\s+push\s*$' || printf '%s' "$SCAN" | grep -qE '\bgit\s+push\s+(origin|upstream)\s*$'; then
      BRANCH=$(current_branch)
      if [[ -n "$BRANCH" ]] && is_protected "$BRANCH"; then
        enforce "$MODE" "Pushing to protected branch '${BRANCH}' is blocked (you're on it)."
      fi
    fi
  fi
fi

# 4. No commit on protected branch
MODE=$(rule_mode no-commit-on-protected)
if rule_active "$MODE"; then
  if printf '%s' "$SCAN" | grep -qE '\bgit\s+commit\b'; then
    BRANCH=$(current_branch)
    if [[ -n "$BRANCH" ]] && is_protected "$BRANCH"; then
      enforce "$MODE" "Committing directly to protected branch '${BRANCH}' is blocked. Create a feature branch first."
    fi
  fi
fi

# 5. No reset --hard
MODE=$(rule_mode no-reset-hard)
if rule_active "$MODE"; then
  if printf '%s' "$SCAN" | grep -qE '\bgit\s+reset\b.*--hard\b'; then
    enforce "$MODE" "git reset --hard is blocked. Use git stash or git reset --soft instead."
  fi
fi

# 6. No discard all changes
MODE=$(rule_mode no-discard-all)
if rule_active "$MODE"; then
  # git checkout . / git checkout -- .
  if printf '%s' "$SCAN" | grep -qE '\bgit\s+checkout\s+(--\s+)?\.(\s|$)'; then
    enforce "$MODE" "git checkout . discards all changes. Stage and commit your work, or use git stash."
  fi
  # git restore .
  if printf '%s' "$SCAN" | grep -qE '\bgit\s+restore\s+\.(\s|$)'; then
    enforce "$MODE" "git restore . discards all changes. Stage and commit your work, or use git stash."
  fi
  # git clean -f / git clean -fd
  if printf '%s' "$SCAN" | grep -qE '\bgit\s+clean\b.*-[a-zA-Z]*f'; then
    enforce "$MODE" "git clean -f deletes untracked files. Review files manually first."
  fi
fi

# 7. No rebase on protected branch
MODE=$(rule_mode no-rebase-on-protected)
if rule_active "$MODE"; then
  if printf '%s' "$SCAN" | grep -qE '\bgit\s+rebase\b'; then
    BRANCH=$(current_branch)
    if [[ -n "$BRANCH" ]] && is_protected "$BRANCH"; then
      enforce "$MODE" "Rebasing while on protected branch '${BRANCH}' is blocked. Switch to a feature branch first."
    fi
  fi
fi

# 8. No add all (require explicit file paths)
MODE=$(rule_mode no-add-all)
if rule_active "$MODE"; then
  # git add -A / git add --all
  if printf '%s' "$SCAN" | grep -qE '\bgit\s+add\s+(-A\b|--all\b)'; then
    enforce "$MODE" "git add -A / --all is blocked. Stage specific files by name."
  fi
  # git add . (but not git add ./specific/path)
  if printf '%s' "$SCAN" | grep -qE '\bgit\s+add\s+\.(\s|$)'; then
    enforce "$MODE" "git add . is blocked. Stage specific files by name."
  fi
fi

# 9. No merge PR without explicit approval (gh pr merge)
MODE=$(rule_mode no-merge-pr)
if rule_active "$MODE"; then
  if printf '%s' "$SCAN" | grep -qE '\bgh\s+pr\s+merge\b'; then
    enforce "$MODE" "gh pr merge requires explicit approval. Create the PR and let the user decide when to merge."
  fi
fi

# All checks passed
exit 0
