# git-governor

A Claude Code plugin that enforces git governance via PreToolUse hooks. Install once, never worry about Claude nuking your git history again.

## What it blocks

| Rule | Default | Description |
|------|---------|-------------|
| `no-amend` | on | Block `git commit --amend` |
| `no-commit-on-protected` | on | Block `git commit` on protected branches |
| `no-push-to-protected` | on | Block `git push` targeting protected branches |
| `no-force-push` | on | Block `--force`, `--force-with-lease`, `+refs` push syntax |
| `no-reset-hard` | on | Block `git reset --hard` |
| `no-discard-all` | on | Block `git checkout .`, `git restore .`, `git clean -f` |
| `no-rebase-on-protected` | on | Block `git rebase` while on a protected branch |

Protected branches default to `main` and `master`.

## Install

```
/install git-governor@allixsenos
```

## Configuration

Drop a `.claude/git-governor.json` in your project root to override defaults:

```json
{
  "protected-branches": ["main", "master", "release/*"],
  "rules": {
    "no-amend": true,
    "no-force-push": true,
    "no-commit-on-protected": true,
    "no-push-to-protected": true,
    "no-reset-hard": true,
    "no-discard-all": true,
    "no-rebase-on-protected": false
  }
}
```

Glob patterns work for branch names (`release/*` matches `release/1.0`).

## License

MIT
