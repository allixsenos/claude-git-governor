#!/usr/bin/env bash
# git-governor test suite
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/hooks/git-governor.sh"
PASS=0
FAIL=0
TOTAL=0

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

# --- Test helpers ---

setup() {
  TEST_DIR=$(mktemp -d)
  # Init a git repo so branch-dependent rules work
  git init -q "$TEST_DIR"
  git -C "$TEST_DIR" commit --allow-empty -m "init" -q
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Build hook input JSON
bash_input() {
  local cmd="$1" cwd="${2:-$TEST_DIR}"
  jq -n --arg cmd "$cmd" --arg cwd "$cwd" \
    '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd}'
}

write_input() {
  local path="$1" cwd="${2:-$TEST_DIR}"
  jq -n --arg path "$path" --arg cwd "$cwd" \
    '{tool_name:"Write",tool_input:{file_path:$path},cwd:$cwd}'
}

edit_input() {
  local path="$1" cwd="${2:-$TEST_DIR}"
  jq -n --arg path "$path" --arg cwd "$cwd" \
    '{tool_name:"Edit",tool_input:{file_path:$path},cwd:$cwd}'
}

# Run hook, capture output and exit code
run_hook() {
  local input="$1"
  OUTPUT=$(echo "$input" | bash "$HOOK" 2>/dev/null) || true
  EXIT_CODE=${PIPESTATUS[1]:-0}
}

# Extract permissionDecision from output
get_decision() {
  echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true
}

# Assertions
expect_deny() {
  local label="$1"
  TOTAL=$((TOTAL + 1))
  local decision
  decision=$(get_decision)
  if [[ "$decision" == "deny" ]]; then
    PASS=$((PASS + 1))
    printf "  ${GREEN}PASS${RESET} %s\n" "$label"
  else
    FAIL=$((FAIL + 1))
    printf "  ${RED}FAIL${RESET} %s (expected deny, got '%s')\n" "$label" "$decision"
  fi
}

expect_ask() {
  local label="$1"
  TOTAL=$((TOTAL + 1))
  local decision
  decision=$(get_decision)
  if [[ "$decision" == "ask" ]]; then
    PASS=$((PASS + 1))
    printf "  ${GREEN}PASS${RESET} %s\n" "$label"
  else
    FAIL=$((FAIL + 1))
    printf "  ${RED}FAIL${RESET} %s (expected ask, got '%s')\n" "$label" "$decision"
  fi
}

expect_allow() {
  local label="$1"
  TOTAL=$((TOTAL + 1))
  local decision
  decision=$(get_decision)
  if [[ -z "$decision" ]]; then
    PASS=$((PASS + 1))
    printf "  ${GREEN}PASS${RESET} %s\n" "$label"
  else
    FAIL=$((FAIL + 1))
    printf "  ${RED}FAIL${RESET} %s (expected allow, got '%s')\n" "$label" "$decision"
  fi
}

# Set up config for a test
set_config() {
  local config="$1"
  mkdir -p "$TEST_DIR/.claude"
  echo "$config" > "$TEST_DIR/.claude/git-governor.json"
}

clear_config() {
  rm -f "$TEST_DIR/.claude/git-governor.json"
}

# --- Tests ---

printf "${BOLD}git-governor test suite${RESET}\n\n"

# ============================================================
printf "${BOLD}Rule: no-amend${RESET}\n"
setup

run_hook "$(bash_input 'git commit --amend')"
expect_deny "blocks git commit --amend"

run_hook "$(bash_input 'git commit --amend -m "fix typo"')"
expect_deny "blocks git commit --amend with message"

git -C "$TEST_DIR" checkout -b feature -q
run_hook "$(bash_input 'git commit -m "normal commit"')"
expect_allow "allows normal commit (on feature branch)"

teardown

# ============================================================
printf "\n${BOLD}Rule: no-force-push${RESET}\n"
setup

run_hook "$(bash_input 'git push --force origin feature')"
expect_deny "blocks git push --force"

run_hook "$(bash_input 'git push --force-with-lease origin feature')"
expect_deny "blocks git push --force-with-lease"

run_hook "$(bash_input 'git push -f origin feature')"
expect_deny "blocks git push -f"

run_hook "$(bash_input 'git push origin +feature')"
expect_deny "blocks git push +refspec"

run_hook "$(bash_input 'git push -u origin feature')"
expect_allow "allows normal push to feature branch"

teardown

# ============================================================
printf "\n${BOLD}Rule: no-push-to-protected${RESET}\n"
setup

run_hook "$(bash_input 'git push origin main')"
expect_deny "blocks push to main"

run_hook "$(bash_input 'git push origin master')"
expect_deny "blocks push to master"

run_hook "$(bash_input 'git push origin feature-branch')"
expect_allow "allows push to feature branch"

teardown

# ============================================================
printf "\n${BOLD}Rule: no-commit-on-protected${RESET}\n"
setup
# We're on main by default after init

run_hook "$(bash_input 'git commit -m "direct commit"')"
expect_deny "blocks commit on main"

git -C "$TEST_DIR" checkout -b feature -q
run_hook "$(bash_input 'git commit -m "feature commit"')"
expect_allow "allows commit on feature branch"

teardown

# ============================================================
printf "\n${BOLD}Rule: no-reset-hard${RESET}\n"
setup

run_hook "$(bash_input 'git reset --hard HEAD')"
expect_deny "blocks git reset --hard HEAD"

run_hook "$(bash_input 'git reset --hard HEAD~3')"
expect_deny "blocks git reset --hard HEAD~3"

run_hook "$(bash_input 'git reset --soft HEAD~1')"
expect_allow "allows git reset --soft"

run_hook "$(bash_input 'git reset HEAD file.txt')"
expect_allow "allows git reset (unstage)"

teardown

# ============================================================
printf "\n${BOLD}Rule: no-discard-all${RESET}\n"
setup

run_hook "$(bash_input 'git checkout .')"
expect_deny "blocks git checkout ."

run_hook "$(bash_input 'git checkout -- .')"
expect_deny "blocks git checkout -- ."

run_hook "$(bash_input 'git restore .')"
expect_deny "blocks git restore ."

run_hook "$(bash_input 'git clean -fd')"
expect_deny "blocks git clean -fd"

run_hook "$(bash_input 'git clean -f')"
expect_deny "blocks git clean -f"

run_hook "$(bash_input 'git checkout -- src/file.ts')"
expect_allow "allows git checkout specific file"

run_hook "$(bash_input 'git restore src/file.ts')"
expect_allow "allows git restore specific file"

teardown

# ============================================================
printf "\n${BOLD}Rule: no-rebase-on-protected${RESET}\n"
setup
# On main by default

run_hook "$(bash_input 'git rebase feature')"
expect_deny "blocks rebase while on main"

git -C "$TEST_DIR" checkout -b feature -q
run_hook "$(bash_input 'git rebase main')"
expect_allow "allows rebase on feature branch"

teardown

# ============================================================
printf "\n${BOLD}Rule: no-add-all${RESET}\n"
setup

run_hook "$(bash_input 'git add .')"
expect_deny "blocks git add ."

run_hook "$(bash_input 'git add -A')"
expect_deny "blocks git add -A"

run_hook "$(bash_input 'git add --all')"
expect_deny "blocks git add --all"

run_hook "$(bash_input 'git add src/file.ts src/other.ts')"
expect_allow "allows git add with specific files"

run_hook "$(bash_input 'git add ./src/specific/file.ts')"
expect_allow "allows git add ./specific/path"

run_hook "$(bash_input 'git add -p')"
expect_allow "allows git add -p (patch mode)"

teardown

# ============================================================
printf "\n${BOLD}Rule: require-git-repo (opt-in)${RESET}\n"
setup
NO_GIT_DIR=$(mktemp -d)

# Default: off — should allow edits outside git
run_hook "$(write_input "$NO_GIT_DIR/file.txt" "$NO_GIT_DIR")"
expect_allow "allows write outside git (rule off by default)"

# Enable rule
set_config '{"rules":{"require-git-repo":true}}'
run_hook "$(write_input "$TEST_DIR/file.txt")"
expect_allow "allows write inside git repo"

# Write outside git with rule on — need config in non-git dir
mkdir -p "$NO_GIT_DIR/.claude"
echo '{"rules":{"require-git-repo":true}}' > "$NO_GIT_DIR/.claude/git-governor.json"
run_hook "$(write_input "$NO_GIT_DIR/file.txt" "$NO_GIT_DIR")"
expect_deny "blocks write outside git repo (rule on)"

# Opt-out via CLAUDE.md
echo "This project will not use git" > "$NO_GIT_DIR/CLAUDE.md"
run_hook "$(write_input "$NO_GIT_DIR/file.txt" "$NO_GIT_DIR")"
expect_allow "allows write outside git when CLAUDE.md opts out"

rm -rf "$NO_GIT_DIR"
clear_config
teardown

# ============================================================
printf "\n${BOLD}False positive prevention (#16)${RESET}\n"
setup

# Quoted strings containing git commands should not trigger
run_hook "$(bash_input "echo \"git rebase is useful\"")"
expect_allow "ignores git text in double-quoted strings"

run_hook "$(bash_input "echo 'git push --force'")"
expect_allow "ignores git text in single-quoted strings"

# Heredoc content should not trigger
INPUT=$(jq -n --arg cwd "$TEST_DIR" '{tool_name:"Bash",tool_input:{command:("cat > /tmp/f.md <<'"'"'EOF'"'"'\ngit rebase main\nEOF\ngh issue create")},cwd:$cwd}')
run_hook "$INPUT"
expect_allow "ignores git text in heredoc content"

# Non-git commands should not trigger
run_hook "$(bash_input 'npm install')"
expect_allow "allows non-git commands"

run_hook "$(bash_input 'ls -la')"
expect_allow "allows ls"

teardown

# ============================================================
printf "\n${BOLD}Config override${RESET}\n"
setup

# Disable a rule via config
set_config '{"rules":{"no-amend":false}}'
run_hook "$(bash_input 'git commit --amend')"
expect_allow "allows amend when rule disabled"
clear_config

# Custom protected branches
set_config '{"protected-branches":["main","master","release/*"]}'
run_hook "$(bash_input 'git push origin release/1.0')"
expect_deny "blocks push to glob-matched protected branch"

run_hook "$(bash_input 'git push origin develop')"
expect_allow "allows push to non-protected branch"

clear_config
teardown

# ============================================================
printf "\n${BOLD}Protocol format${RESET}\n"
setup

run_hook "$(bash_input 'git commit --amend')"
TOTAL=$((TOTAL + 1))
# Verify hookSpecificOutput structure
HAS_HOOK_OUTPUT=$(echo "$OUTPUT" | jq 'has("hookSpecificOutput")' 2>/dev/null || echo false)
HAS_EVENT=$(echo "$OUTPUT" | jq '.hookSpecificOutput.hookEventName == "PreToolUse"' 2>/dev/null || echo false)
HAS_REASON=$(echo "$OUTPUT" | jq '.hookSpecificOutput | has("permissionDecisionReason")' 2>/dev/null || echo false)
if [[ "$HAS_HOOK_OUTPUT" == "true" ]] && [[ "$HAS_EVENT" == "true" ]] && [[ "$HAS_REASON" == "true" ]]; then
  PASS=$((PASS + 1))
  printf "  ${GREEN}PASS${RESET} deny output uses hookSpecificOutput format\n"
else
  FAIL=$((FAIL + 1))
  printf "  ${RED}FAIL${RESET} deny output missing hookSpecificOutput fields\n"
fi

teardown

# ============================================================
# Summary
printf "\n${BOLD}Results: ${PASS}/${TOTAL} passed"
if [[ $FAIL -gt 0 ]]; then
  printf ", ${RED}${FAIL} failed${RESET}"
fi
printf "${RESET}\n"

exit $FAIL
