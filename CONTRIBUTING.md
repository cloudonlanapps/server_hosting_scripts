# Contributing to server_hosting_scripts

This repo holds the generic tooling that deploys a server: the conf setup,
deploy, restart, restore, nginx and security scripts, and the `justfile`
that a deployment imports. It names no product. Products pin it by commit:
for example, `[tooling] ref = …` in a `deploy_servers` product config.

A change here reaches a deployment only when that pin is moved, so a merge
alone changes nothing that is running.

## What needs an issue

- **A change to what a script does**, or to what a conf or the `justfile`
  accepts: open an issue first, branch, and merge it through a PR.
- **Documentation only**, such as the README or this file: commit straight to `main`.

Name the downstream issue when a change follows one (`deploy_servers#N`).

## Workflow

```
1. Open an issue            (status:triage)
2. Agree the scope          (status:ready)
3. Branch from main         (status:in-progress)
4. Change and check it      (on a dev deployment before beta or prod)
5. Open a PR: "Fixes #N"
6. Squash-merge to main     (the status label comes off as the issue closes)
7. Move the pin             (in each product that should take the change)
```

## Branch naming

`task/<issue>-<short-name>`, for example `task/19-remove-conf-scripts`.
A branch is kept on the remote after its PR merges.

## Commits and PRs

- The subject says what the change does, in plain words.
- The PR body links the issue (`Fixes #N`) and says how the change was
  checked, and on which deployment.
- `git add` named files, never `-A`.

## Merging

- **Squash** by default. Use **rebase** only for a series whose commits each stand
  alone.
- Never `--merge`, and never delete the branch on merge.

## Labels

**Status — required.** Every open issue carries exactly one `status:*` label.
Closed issues carry none: closing is the end state, so the label is removed when
the issue closes, not replaced. There is no `status:done`.

| From | To | When |
|---|---|---|
| (none) | `status:triage` | When the issue is filed |
| `status:triage` | `status:ready` | Scope agreed |
| `status:ready` | `status:in-progress` | The branch is created and work starts |
| `status:in-progress` | `status:blocked` | Waiting on another repo, a host or a decision |
| `status:in-progress` | `status:needs-info` | Waiting on the user for an answer |
| `status:blocked` / `status:needs-info` | `status:in-progress` | Unblocked; work resumed |
| any open `status:*` | `status:deferred` | Parked for an unknown future; the issue stays **open** |
| `status:deferred` | `status:triage` / `status:ready` | Picked up again |
| any `status:*` | (removed) | The PR merges and closes the issue, or the issue is closed by hand |

Change a status by removing the old label and adding the new one in one call:

```bash
gh issue edit N --remove-label "status:ready" --add-label "status:in-progress"
```

**Deferring is not closing.** `status:deferred` parks an issue nobody plans to
work on yet. It stays open, keeps its history, and is listed with
`gh issue list --label status:deferred`. Leave a comment saying why. Close it
only when it is done, or when it is dropped on purpose.

**Kind — optional.** `bug`, `enhancement`, `documentation` and the other GitHub
defaults say what kind of change an issue is.

**Priority — not a label.** Priority and order of work are tracked outside
GitHub.

## Working with Claude Code

1. Work from an issue, except for documentation.
2. Branch from `main`.
3. Never push, open a PR, merge, move a product's pin or deploy without the
   user's confirmation.
4. Never put a secret in this repo. Scripts read secrets from `pass` at the
   paths a conf names, and never hold their values.
