# Git Canary — Deception Filesystem

A honeypot layer built entirely on Git primitives. Decoy files containing
convincing but fake developer credentials live in the object store — invisible
to the filesystem until a git operation materialises them. That materialisation
triggers a smudge filter which logs the event, dispatches a GitHub Actions
workflow, and opens a tracking issue.

No agent. No daemon. No OS-level hooks. Git itself is the detection layer.

---

## How It Works

```
.git/objects/  ──►  [canary-smudge]  ──►  working tree
 object store     alert fires here        files land on disk
```

Git separates stored content (the object store) from on-disk content (the
working tree). Sparse checkout keeps honeypot files in the object store only —
they never appear on disk until someone explicitly runs a git materialisation
command. That command must pass through the smudge filter, which is where
detection happens.

| Action | Alert? | Reason |
|---|---|---|
| `ls` / `dir` | No | Filesystem read — git not involved |
| `git ls-files` | No | Index metadata only |
| `git log --all` | No | Object metadata only |
| `git show HEAD:decoy/aws` | No | Stdout only — smudge not called |
| `git checkout <branch>` | **Yes** | Smudge fires per file |
| `git restore decoy/aws` | **Yes** | Smudge fires |
| `git clone <repo>` | **Yes** | Smudge fires on initial materialisation |
| `git pull` | **Yes** | Smudge fires on changed files |
| `git stash pop` | **Yes** | Smudge fires on restored files |

---

## Repository Layout

```
.
├── .github/
│   └── workflows/
│       └── canary-alert.yml      ← receives dispatch, opens issue
├── .git/
│   ├── canary/
│   │   └── access.log            ← append-only local log
│   ├── hooks/
│   │   ├── canary-smudge         ← per-file alert + GitHub dispatch
│   │   ├── post-checkout         ← per-operation branch alert
│   │   └── post-merge            ← alert on git pull
│   ├── info/
│   │   └── sparse-checkout       ← keeps decoy/ off disk
│   └── config                    ← filter definition + canary config
├── .gitattributes                ← marks canary paths
├── setup-canary.sh               ← one-time setup per machine
├── decoy/
│   ├── aws-credentials           ← fake AWS key material
│   └── database.env              ← fake DB + service credentials
└── real/
    └── README.md                 ← legitimate project content
```

---

## Prerequisites

| Platform | Requirement |
|---|---|
| Linux | git ≥ 2.25, bash, curl |
| macOS | git ≥ 2.25 (`brew install git` if Xcode git is older), curl |
| Windows | Git for Windows ≥ 2.25 — bundles sh.exe, curl, id, hostname |

Check your version:
```bash
git --version
```

---

## Quick Start

### 1 — Clone and enter the repo

```bash
git clone https://github.com/your-org/your-repo.git
cd your-repo
```

### 2 — Copy hooks into .git/hooks/

```bash
cp hooks/canary-smudge  .git/hooks/canary-smudge
cp hooks/post-checkout  .git/hooks/post-checkout
cp hooks/post-merge     .git/hooks/post-merge
```

On Linux / macOS make them executable:
```bash
chmod +x .git/hooks/canary-smudge .git/hooks/post-checkout .git/hooks/post-merge
```

On Windows run from Git Bash — no chmod needed.

### 3 — Configure GitHub alerting

Create a GitHub personal access token with `repo` scope, then store it locally.
This value is **never committed**:

```bash
git config canary.githubToken  'ghp_xxxxxxxxxxxxxxxxxxxx'
git config canary.githubRepo   'your-org/your-repo'
```

### 4 — Run setup

```bash
# Linux / macOS
sh setup-canary.sh

# Windows — run from Git Bash
sh setup-canary.sh
```

### 5 — Verify

```bash
# Should show nothing (decoy/ excluded from working tree)
ls decoy/

# Should show decoy files (they exist in the object store)
git ls-files decoy/

# Trigger manually to test — this fires the alert
git checkout -- decoy/aws-credentials
cat .git/canary/access.log
```

---

## Configuration Reference

All canary options are stored in `.git/config` (local, never committed):

```bash
# GitHub dispatch + issue creation
git config canary.githubToken  'ghp_xxxxxxxxxxxxxxxxxxxx'
git config canary.githubRepo   'owner/repo'

# Optional: plain HTTP webhook (Slack, custom endpoint, etc.)
git config canary.webhookUrl   'https://hooks.slack.com/services/...'

# Optional: label to apply to created issues (default: canary)
git config canary.issueLabel   'canary'
```

View current config:
```bash
git config --list | grep canary
```

---

## GitHub Actions Integration

### How the dispatch flow works

```
canary-smudge fires
       │
       ▼
POST /repos/{owner}/{repo}/dispatches
  event_type: canary_triggered
  client_payload: { file, user, host, ts, event }
       │
       ▼
.github/workflows/canary-alert.yml triggers
       │
       ├──► Creates GitHub issue  "[CANARY] decoy/aws-credentials accessed"
       └──► (extend here: Slack, PagerDuty, email, etc.)
```

### The workflow file

Place `.github/workflows/canary-alert.yml` in your repository.
It listens for `repository_dispatch` events with type `canary_triggered`:

```yaml
on:
  repository_dispatch:
    types: [canary_triggered]
```

The `client_payload` fields available inside the workflow:

| Field | Content |
|---|---|
| `github.event.client_payload.file` | Path of the accessed file |
| `github.event.client_payload.user` | OS username on the triggering machine |
| `github.event.client_payload.host` | Hostname of the triggering machine |
| `github.event.client_payload.ts` | ISO 8601 timestamp |
| `github.event.client_payload.event` | Always `SMUDGE` for file materialisation |

### PAT permissions required

The PAT used for `canary.githubToken` needs:
- `repo` — to dispatch workflows and create issues on private repos
- `public_repo` — sufficient for public repos

---

## Decoy File Design

The files in `decoy/` contain fake but realistic-looking credential material.
**None of these values grant access to anything.** They follow real formats
closely enough to appear credible to an attacker enumerating a repository.

### decoy/aws-credentials

Follows the standard AWS credentials file format. The access key ID matches
the `AKIA` prefix pattern. The secret is the correct length and character set.

### decoy/database.env

Follows a `.env` convention used by most web frameworks (Rails, Django, Next.js,
Laravel). Contains fake connection strings, API keys, and a JWT secret — the
combination that would be genuinely valuable if real.

Customise the hostnames and service names to match your actual infrastructure
naming conventions. The more the decoy resembles your real config, the more
convincing it is as bait.

---

## Platform Notes

### Windows — line endings

The most common Windows failure. If `core.autocrlf=true` (the Windows default),
hook scripts get CRLF line endings and fail with:

```
/bin/sh: bad interpreter: No such file or directory
```

`setup-canary.sh` sets `core.autocrlf=false` and `core.eol=lf` automatically.
If you run it from Git Bash before touching the hooks, this is handled.

### Windows — smudge path

The filter is configured as:

```ini
smudge = sh .git/hooks/canary-smudge %f
```

The explicit `sh` invocation makes the path reliable across all platforms.
Without it, Windows may not recognise the bare script path as executable.

### macOS — git version

macOS ships git 2.x via Xcode Command Line Tools.
`git sparse-checkout` requires 2.25+. Check and upgrade if needed:

```bash
git --version
brew install git   # if needed
```

### Hooks are not cloned

`.git/hooks/` is never transferred by `git clone` — this is git's design.
Every machine needs `setup-canary.sh` run after cloning. Document this in your
onboarding steps or automate it via a Makefile target.

---

## Local Log Format

`.git/canary/access.log` — tab-separated, append-only:

```
2025-10-14T09:23:09Z    SMUDGE              alice@LAPTOP-XYZ    decoy/aws-credentials
2025-10-14T09:23:09Z    SMUDGE              alice@LAPTOP-XYZ    decoy/database.env
2025-10-14T09:23:11Z    CHECKOUT-BRANCH     alice@LAPTOP-XYZ    main
2025-10-14T09:23:11Z    CANARY-IN-BRANCH    alice@LAPTOP-XYZ    decoy/aws-credentials
```

Fields: `timestamp`, `event`, `user@host`, `filepath`

---

## Limitations

**Git hooks intercept git operations — not OS-level file I/O.**

Once a honeypot file is on disk, `cat`, `cp`, and editor opens do not re-trigger
the smudge filter. The mitigation is sparse checkout: keep honeypot files off disk
by default so every access requires a git command, which routes through smudge.

The periodic reset closes this window further:

```bash
# Linux / macOS crontab — resets every hour
0 * * * * cd /path/to/repo && git checkout -- decoy/ >/dev/null 2>&1

# Windows Task Scheduler
# Program: C:\Program Files\Git\bin\sh.exe
# Arguments: -c "git -C C:/path/to/repo checkout -- decoy/"
```

**`git show HEAD:decoy/file` does not trigger smudge.** It reads the object
directly to stdout without writing to the working tree. This is a genuine gap —
an attacker reading content this way is not detected by the local hooks.
Server-side hooks (if the repo is hosted on a self-managed git server) can
cover this case.

---

## Security Considerations

- The `canary.githubToken` PAT is stored in `.git/config` — local, never
  committed. Back it up separately from the repo.
- Decoy files contain no real credentials. Verify this before committing.
- The `required = true` filter setting means git will refuse to checkout
  canary files if the smudge script is missing — preventing silent bypass
  by deleting the hook.
- Rotate decoy content periodically. Stale formats (old key prefixes, deprecated
  services) reduce believability.
