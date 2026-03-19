# git-governor

A Claude Code plugin that enforces git governance via PreToolUse hooks. Install once, never worry about Claude nuking your git history again.

## Rules

| Rule | Default | Description |
|------|---------|-------------|
| `no-amend` | deny | Block `git commit --amend` |
| `no-commit-on-protected` | deny | Block `git commit` on protected branches |
| `no-push-to-protected` | deny | Block `git push` targeting protected branches |
| `no-force-push` | deny | Block `--force`, `--force-with-lease`, `+refs` push syntax |
| `no-reset-hard` | deny | Block `git reset --hard` |
| `no-discard-all` | deny | Block `git checkout .`, `git restore .`, `git clean -f` |
| `no-rebase-on-protected` | deny | Block `git rebase` while on a protected branch |
| `no-add-all` | deny | Block `git add .` and `git add -A` (require explicit file paths) |
| `require-git-repo` | **allow** | Block `Write`/`Edit` to files outside a git repo (opt-in) |

Protected branches default to `main` and `master`.

The `require-git-repo` rule blocks file edits to paths that aren't inside a git repository. A project can opt out by including a phrase like "will not use git" in its `CLAUDE.md`.

## Install

```
/plugin install allixsenos/claude-git-governor
```

## Configuration

Configure interactively with the built-in skill:

```
/git-governor:git-governor                              # show effective config
/git-governor:git-governor set no-amend ask             # set a rule
/git-governor:git-governor set no-add-all allow --global  # set globally
/git-governor:git-governor protect release/*            # add protected branch
/git-governor:git-governor reset                        # remove project config
```

Or drop a `.claude/git-governor.json` in your project root to override defaults:

```json
{
  "protected-branches": ["main", "master", "release/*"],
  "rules": {
    "no-amend": "deny",
    "no-force-push": "deny",
    "no-commit-on-protected": "ask",
    "no-push-to-protected": "deny",
    "no-reset-hard": "deny",
    "no-discard-all": "ask",
    "no-rebase-on-protected": "allow",
    "no-add-all": "ask",
    "require-git-repo": "deny"
  }
}
```

Glob patterns work for branch names (`release/*` matches `release/1.0`).

### Rule modes

Every rule supports three modes:

| Mode | Effect |
|------|--------|
| `"deny"` | Hard block — tool call is prevented |
| `"ask"` | Prompt the user for confirmation before proceeding |
| `"allow"` | Disabled — no check performed |

Use `"deny"` for operations that should never happen (force push, reset --hard). Use `"ask"` for operations where you want a human checkpoint (committing on protected, discarding changes). Invalid values are treated as errors and blocked.

### Config precedence

| Scope | Path | Precedence |
|-------|------|------------|
| Project | `<project>/.claude/git-governor.json` | Highest |
| Global | `~/.claude/git-governor.json` | Middle |
| Defaults | Built into the hook | Lowest |

For rules, each rule is resolved independently: project > global > default. For `protected-branches`, the first config that defines the key wins entirely (no merging).

## License

MIT
