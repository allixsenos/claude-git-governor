---
name: git-governor
description: >
  View and configure git-governor rules and protected branches. Use when the
  user invokes /git-governor to view config, or with subcommands to set rule
  modes (deny/ask/allow), manage protected branch patterns, or reset config.
---

# git-governor

View and configure the git-governor plugin.

## Usage

```
/git-governor [command] [args] [--global]
```

## Commands

| Command | Description |
|---------|-------------|
| *(none)* | Show effective config (default) |
| `set <rule> <mode>` | Set a rule's mode |
| `protect <pattern>` | Add a protected branch pattern |
| `unprotect <pattern>` | Remove a protected branch pattern |
| `reset` | Delete the config file |

The `--global` flag targets `~/.claude/git-governor.json` instead of the project config.

## Config file locations

| Scope | Path | Precedence |
|-------|------|------------|
| Project | `<project>/.claude/git-governor.json` | Highest (wins) |
| Global | `~/.claude/git-governor.json` | Middle |
| Defaults | Built into the hook | Lowest |

For rules: project overrides global overrides defaults.
For protected branches: the first config that defines `protected-branches` wins entirely (no merging).

## Valid rules

| Rule | Default | Description |
|------|---------|-------------|
| `no-amend` | `deny` | Block `git commit --amend` |
| `no-commit-on-protected` | `deny` | Block commits directly on protected branches |
| `no-push-to-protected` | `deny` | Block pushing to protected branches |
| `no-force-push` | `deny` | Block `--force`, `--force-with-lease`, and `+refspec` pushes |
| `no-reset-hard` | `deny` | Block `git reset --hard` |
| `no-discard-all` | `deny` | Block `git checkout .`, `git restore .`, `git clean -f` |
| `no-rebase-on-protected` | `deny` | Block rebase while on a protected branch |
| `no-add-all` | `deny` | Block `git add -A` and `git add .` |
| `require-git-repo` | `allow` | Require a git repo for Write/Edit operations |

## Valid modes

| Mode | Effect |
|------|--------|
| `deny` | Hard block — tool call prevented |
| `ask` | Prompt user for confirmation |
| `allow` | Disabled — no check |

## Instructions

ARGUMENTS: provided after the skill name, e.g. `/git-governor set no-amend ask`

### Default command (no arguments, or `status`)

1. Read defaults from the table above.
2. Read global config at `~/.claude/git-governor.json` if it exists.
3. Read project config at `<CWD>/.claude/git-governor.json` if it exists.
4. Compute the effective value for each rule using merge precedence: project > global > default.
5. Display a table with columns: Rule, Description, Default, Global, Project, Effective.
   - For Default/Global/Project columns: show the mode if set, or `-` if not set at that level.
   - For Effective: show the winning value (project > global > default).
6. Display the effective protected branches and their source.
7. Print short instructions for changing settings.

Example output:
```
| Rule                    | Description                         | Default | Global | Project | Effective |
|-------------------------|-------------------------------------|---------|--------|---------|-----------|
| no-amend                | Block git commit --amend            | deny    | -      | ask     | ask       |
| no-commit-on-protected  | Block commits on protected branches | deny    | -      | -       | deny      |
| no-push-to-protected    | Block pushing to protected branches | deny    | deny   | -       | deny      |
| no-force-push           | Block force push                    | deny    | -      | -       | deny      |
| no-reset-hard           | Block git reset --hard              | deny    | -      | -       | deny      |
| no-discard-all          | Block checkout/restore/clean all    | deny    | -      | allow   | allow     |
| no-rebase-on-protected  | Block rebase on protected branches  | deny    | -      | -       | deny      |
| no-add-all              | Block git add -A / git add .        | deny    | -      | -       | deny      |
| require-git-repo        | Require git repo for file edits     | allow   | -      | -       | allow     |

Protected branches: ["main", "master"] (default)

To change a rule:   /git-governor set <rule> <mode>        (modes: deny, ask, allow)
To add a branch:    /git-governor protect <pattern>
To remove a branch: /git-governor unprotect <pattern>
Add --global to target ~/.claude/git-governor.json instead of the project config.
```

### Command: `set <rule> <mode>`

1. Validate `<rule>` against the valid rules list. If invalid, show the valid rules and stop.
2. Validate `<mode>` against: `deny`, `ask`, `allow`. If invalid, show valid modes and stop.
3. Determine target file:
   - Without `--global`: `<CWD>/.claude/git-governor.json`
   - With `--global`: `~/.claude/git-governor.json`
4. Read the target file. If it doesn't exist, start with `{}`.
5. Set `.rules.<rule>` to the mode value (as a string).
6. Ensure the `.rules` object exists in the JSON.
7. Create the parent directory if needed (`mkdir -p` via Bash).
8. Write the complete JSON back with 2-space indentation.
9. Confirm: `Set <rule> = "<mode>" in <scope> config.`

### Command: `protect <pattern>`

1. Determine target file (project or global based on `--global`).
2. Read the target file. If it doesn't exist, start with `{}`.
3. Read the current `protected-branches` array. If absent, start with `[]`.
4. If the pattern is already in the array, inform the user and stop.
5. Append the pattern to the array.
6. Write the complete JSON back with 2-space indentation.
7. Confirm and show the resulting protected branches list.

### Command: `unprotect <pattern>`

1. Determine target file (project or global based on `--global`).
2. Read the target file. If it doesn't exist, inform the user there's nothing to change.
3. Read the current `protected-branches` array. If absent, inform the user.
4. If the pattern is not in the array, inform the user and stop.
5. Remove the pattern from the array.
6. If the array is now empty, remove the `protected-branches` key entirely.
7. Write the complete JSON back with 2-space indentation.
8. Confirm and show the resulting protected branches list.

### Command: `reset`

1. Determine target file (project or global based on `--global`).
2. If the file doesn't exist, inform the user there's nothing to reset.
3. Delete the file using Bash `rm`.
4. Confirm: `Deleted <scope> config. Defaults will be used.`

### Command: `help`

Display the usage summary showing all commands, valid rules, and valid modes.

### JSON handling

- Always use the Read tool to read config files before modifying.
- Always use the Write tool to write the complete JSON content (not Edit, since the changes may restructure the object).
- Use 2-space indentation in JSON output.
- Preserve any existing keys that are not being modified.
- Use `jq` via Bash for JSON manipulation if needed, but prefer reading and writing via the dedicated tools.
