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
| `require-git-repo` | **off** | Block `Write`/`Edit` to files outside a git repo (opt-in) |

Protected branches default to `main` and `master`.

The `require-git-repo` rule blocks file edits to paths that aren't inside a git repository. A project can opt out by including a phrase like "will not use git" in its `CLAUDE.md`.

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
    "no-rebase-on-protected": false,
    "require-git-repo": true
  }
}
```

Glob patterns work for branch names (`release/*` matches `release/1.0`).

## License

MIT
