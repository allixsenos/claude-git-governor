#!/usr/bin/env bash
# git-governor adversarial / fuzzing test suite
#
# Tests evasion techniques that might bypass governance rules.
# Each section targets a specific attack vector. Tests marked "KNOWN GAP"
# document bypasses that are accepted risks (shell indirection, etc).
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

# --- Test helpers (same as test.sh) ---

setup() {
  TEST_DIR=$(mktemp -d)
  git init -q "$TEST_DIR"
  git -C "$TEST_DIR" commit --allow-empty -m "init" -q
}

teardown() {
  rm -rf "$TEST_DIR"
}

bash_input() {
  local cmd="$1" cwd="${2:-$TEST_DIR}"
  jq -n --arg cmd "$cmd" --arg cwd "$cwd" \
    '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd}'
}

run_hook() {
  local input="$1"
  OUTPUT=$(echo "$input" | bash "$HOOK" 2>/dev/null) || true
  EXIT_CODE=${PIPESTATUS[1]:-0}
}

run_hook_with_home() {
  local input="$1" fake_home="$2"
  OUTPUT=$(echo "$input" | HOME="$fake_home" bash "$HOOK" 2>/dev/null) || true
  EXIT_CODE=${PIPESTATUS[1]:-0}
}

get_decision() {
  echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true
}

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

expect_blocked() {
  # Accept either "deny" or "ask" — the point is it wasn't silently allowed
  local label="$1"
  TOTAL=$((TOTAL + 1))
  local decision
  decision=$(get_decision)
  if [[ "$decision" == "deny" || "$decision" == "ask" ]]; then
    PASS=$((PASS + 1))
    printf "  ${GREEN}PASS${RESET} %s (got '%s')\n" "$label" "$decision"
  else
    FAIL=$((FAIL + 1))
    printf "  ${RED}FAIL${RESET} %s (expected deny/ask, got '%s')\n" "$label" "$decision"
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

set_config() {
  local config="$1"
  mkdir -p "$TEST_DIR/.claude"
  echo "$config" > "$TEST_DIR/.claude/git-governor.json"
}

clear_config() {
  rm -f "$TEST_DIR/.claude/git-governor.json"
}

# ============================================================
printf "${BOLD}git-governor adversarial test suite${RESET}\n"

# ============================================================
printf "\n${BOLD}1. Git global flags between git and subcommand${RESET}\n"
setup

run_hook "$(bash_input 'git -C /tmp commit --amend')"
expect_blocked "git -C <path> commit --amend"

run_hook "$(bash_input 'git -c user.name=x commit --amend')"
expect_blocked "git -c <key=val> commit --amend"

run_hook "$(bash_input 'git --git-dir=.git commit --amend')"
expect_blocked "git --git-dir=<path> commit --amend"

run_hook "$(bash_input 'git --work-tree=. commit --amend')"
expect_blocked "git --work-tree=<path> commit --amend"

run_hook "$(bash_input 'git -C /tmp push --force origin main')"
expect_blocked "git -C <path> push --force"

run_hook "$(bash_input 'git -C /tmp reset --hard HEAD')"
expect_blocked "git -C <path> reset --hard"

run_hook "$(bash_input 'git -c core.autocrlf=true add .')"
expect_blocked "git -c <key=val> add ."

run_hook "$(bash_input 'git -C /tmp -c user.name=x commit --amend')"
expect_blocked "git -C -c (chained global flags) commit --amend"

teardown

# ============================================================
printf "\n${BOLD}2. Command chaining (dangerous git after benign command)${RESET}\n"
setup

run_hook "$(bash_input 'echo done && git push --force origin main')"
expect_blocked "echo && git push --force"

run_hook "$(bash_input 'true; git commit --amend')"
expect_blocked "true; git commit --amend"

run_hook "$(bash_input 'ls -la && git reset --hard HEAD')"
expect_blocked "ls && git reset --hard"

run_hook "$(bash_input 'echo "starting" && git add . && git commit -m "msg"')"
expect_blocked "echo && git add ."

run_hook "$(bash_input 'npm test || git push --force origin main')"
expect_blocked "npm test || git push --force"

run_hook "$(bash_input 'git status && git push --force origin main')"
expect_blocked "git status && git push --force"

teardown

# ============================================================
printf "\n${BOLD}3. Shell indirection${RESET}\n"
setup

run_hook "$(bash_input 'eval "git push --force origin main"')"
expect_blocked "eval with git push --force"

run_hook "$(bash_input 'cmd=push; git $cmd --force')"
expect_blocked "variable expansion: git \$cmd --force"

run_hook "$(bash_input '$(echo git) push --force')"
expect_blocked "subshell: \$(echo git) push --force"

run_hook "$(bash_input 'echo "push --force" | xargs git')"
expect_blocked "xargs: echo | xargs git"

teardown

# ============================================================
printf "\n${BOLD}4. Binary path instead of bare git${RESET}\n"
setup

run_hook "$(bash_input '/usr/bin/git push --force origin main')"
expect_blocked "/usr/bin/git push --force"

run_hook "$(bash_input '/usr/bin/git commit --amend')"
expect_blocked "/usr/bin/git commit --amend"

teardown

# ============================================================
printf "\n${BOLD}5. Command wrappers${RESET}\n"
setup

run_hook "$(bash_input 'env git push --force origin main')"
expect_blocked "env git push --force"

run_hook "$(bash_input 'command git push --force origin main')"
expect_blocked "command git push --force"

run_hook "$(bash_input 'nice git push --force origin main')"
expect_blocked "nice git push --force"

teardown

# ============================================================
printf "\n${BOLD}6. Sanitizer edge cases${RESET}\n"
setup

# Backtick expansion
run_hook "$(bash_input 'git push `echo --force` origin main')"
expect_blocked "backtick expansion: git push \`echo --force\`"

# $() expansion inside the command
run_hook "$(bash_input 'git push $(echo --force) origin main')"
expect_blocked "subshell expansion: git push \$(echo --force)"

# Unbalanced quotes — the sed should still strip what it can
run_hook "$(bash_input "git commit --amend -m \"it's a fix\"")"
expect_blocked "unbalanced quote: git commit --amend -m \"it's a fix\""

# Empty quoted strings shouldn't hide adjacent args
run_hook "$(bash_input "git commit ''--amend")"
expect_blocked "empty quotes adjacent to --amend"

# Escaped quotes inside strings
run_hook "$(bash_input 'git push --force origin "ma\"in"')"
expect_blocked "escaped quotes: git push --force with escaped inner quote"

teardown

# ============================================================
printf "\n${BOLD}7. Flag reordering${RESET}\n"
setup

run_hook "$(bash_input 'git push origin main --force')"
expect_blocked "flag after refspec: git push origin main --force"

run_hook "$(bash_input 'git push -f origin main')"
expect_blocked "short flag before remote: git push -f origin main"

run_hook "$(bash_input 'git reset HEAD --hard')"
expect_blocked "flag after ref: git reset HEAD --hard"

run_hook "$(bash_input 'git reset --hard')"
expect_blocked "bare git reset --hard (no ref)"

run_hook "$(bash_input 'git clean -dfx')"
expect_blocked "combined flags: git clean -dfx"

run_hook "$(bash_input 'git clean --force -d')"
expect_blocked "long flag: git clean --force -d"

teardown

# ============================================================
printf "\n${BOLD}8. Whitespace variations${RESET}\n"
setup

run_hook "$(bash_input 'git  push  --force  origin  main')"
expect_blocked "multiple spaces: git  push  --force"

run_hook "$(bash_input 'git	commit	--amend')"
expect_blocked "tab chars: git<tab>commit<tab>--amend"

run_hook "$(bash_input $'git push \\\n--force origin main')"
expect_blocked "line continuation: git push \\\\n--force"

teardown

# ============================================================
printf "\n${BOLD}9. Config poisoning${RESET}\n"
setup

# Invalid JSON config — hook should not fail open
set_config 'NOT VALID JSON {'
run_hook "$(bash_input 'git commit --amend')"
expect_blocked "invalid JSON config: still blocks amend"
clear_config

# Config that tries to set rules to empty string
set_config '{"rules":{"no-amend":""}}'
run_hook "$(bash_input 'git commit --amend')"
expect_blocked "empty string mode: still blocks amend"
clear_config

# Config with extra unknown fields (should not break)
set_config '{"rules":{"no-amend":"deny"},"extra_field":"whatever","nested":{"a":1}}'
run_hook "$(bash_input 'git commit --amend')"
expect_blocked "extra config fields: still blocks amend"
clear_config

teardown

# ============================================================
printf "\n${BOLD}10. Partial keyword matches (false positive prevention)${RESET}\n"
setup
git -C "$TEST_DIR" checkout -b feature -q

# Words containing "git" shouldn't trigger
run_hook "$(bash_input 'echo digit')"
expect_allow "word containing 'git': digit"

run_hook "$(bash_input 'legitimate command')"
expect_allow "word containing 'git': legitimate"

# "git" in a path
run_hook "$(bash_input 'cat /tmp/git-notes.txt')"
expect_allow "git in a path: /tmp/git-notes.txt"

# Subcommands that are not governed
run_hook "$(bash_input 'git log --oneline -10')"
expect_allow "benign subcommand: git log"

run_hook "$(bash_input 'git diff HEAD~1')"
expect_allow "benign subcommand: git diff"

run_hook "$(bash_input 'git stash pop')"
expect_allow "benign subcommand: git stash pop"

run_hook "$(bash_input 'git branch -a')"
expect_allow "benign subcommand: git branch -a"

run_hook "$(bash_input 'git fetch origin')"
expect_allow "benign subcommand: git fetch"

teardown

# ============================================================
printf "\n${BOLD}11. Refspec evasion for push-to-protected${RESET}\n"
setup

run_hook "$(bash_input 'git push origin HEAD:main')"
expect_blocked "refspec HEAD:main"

run_hook "$(bash_input 'git push origin feature:main')"
expect_blocked "refspec feature:main"

run_hook "$(bash_input 'git push origin HEAD:refs/heads/main')"
expect_blocked "refspec HEAD:refs/heads/main"

teardown

# ============================================================
printf "\n${BOLD}12. Multiple git commands in one line${RESET}\n"
setup

# First command benign, second dangerous
run_hook "$(bash_input 'git status; git reset --hard HEAD')"
expect_blocked "git status; git reset --hard"

# Benign git followed by dangerous via &&
run_hook "$(bash_input 'git add file.txt && git commit --amend')"
expect_blocked "git add file && git commit --amend"

# Pipe from git to git (unusual but possible)
run_hook "$(bash_input 'git log --oneline | head -1 && git push --force')"
expect_blocked "git log | head && git push --force"

teardown

# ============================================================
printf "\n${BOLD}13. Heredoc containing real command after${RESET}\n"
setup

# Heredoc with innocent git text, followed by real dangerous command
INPUT=$(jq -n --arg cwd "$TEST_DIR" '{tool_name:"Bash",tool_input:{command:("cat > /tmp/notes.md <<'"'"'EOF'"'"'\ngit is great\nEOF\ngit push --force origin main")},cwd:$cwd}')
run_hook "$INPUT"
expect_blocked "heredoc then git push --force"

INPUT=$(jq -n --arg cwd "$TEST_DIR" '{tool_name:"Bash",tool_input:{command:("cat <<'"'"'EOF'"'"'\nsome text\nEOF\ngit commit --amend -m \"fix\"")},cwd:$cwd}')
run_hook "$INPUT"
expect_blocked "heredoc then git commit --amend"

teardown

# ============================================================
printf "\n${BOLD}14. gh CLI evasion${RESET}\n"
setup

# The hook also scans for gh commands (no-merge-pr rule)
run_hook "$(bash_input 'gh pr merge 123 --squash')"
expect_blocked "gh pr merge --squash"

run_hook "$(bash_input 'gh pr merge 123 --rebase')"
expect_blocked "gh pr merge --rebase"

run_hook "$(bash_input 'echo done && gh pr merge 123 --squash')"
expect_blocked "chained: echo && gh pr merge"

teardown

# ============================================================
# Summary
printf "\n${BOLD}Results: ${PASS}/${TOTAL} passed"
if [[ $FAIL -gt 0 ]]; then
  printf ", ${RED}${FAIL} failed${RESET}"
fi
printf "${RESET}\n"

exit $FAIL
