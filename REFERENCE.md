# Reference — Smudge Filters & Sparse Checkout

---

## Part 1 — Smudge & Clean Filters

### What they are

Git filters are transformation scripts that run automatically as content moves
between the object store and the working tree. There are two directions:

```
working tree  ──[clean]──►  object store   (git add / git commit)
object store  ──[smudge]──► working tree   (git checkout / git restore / git clone)
```

- **clean** — runs when a file moves from disk into the index (staging). Use it
  to strip secrets, normalise line endings, or compress before committing.
- **smudge** — runs when a file moves from the object store onto disk. Use it to
  inject secrets, decompress, or — as in this system — fire an alert.

Both receive file content on stdin and must write the (possibly transformed)
content to stdout. Git writes whatever stdout produces to the destination.

### Declaring a filter in .gitattributes

```gitattributes
# Syntax: <pathspec>  filter=<driver-name>
decoy/**        filter=canary
*.env           filter=canary
secrets/*.json  filter=canary
```

The driver name (`canary` here) is arbitrary. It must match the name used in
the git config definition below.

### Defining the filter driver

Filter drivers live in `.git/config` (local) or `~/.gitconfig` (global).
Never commit filter definitions — they reference local script paths:

```ini
[filter "canary"]
    smudge   = sh .git/hooks/canary-smudge %f
    clean    = cat
    required = true
```

- `%f` — expands to the file path being processed, relative to the repo root.
  This is how the smudge script knows which file triggered it.
- `clean = cat` — pass content through unchanged on staging. We only want
  alerts on checkout, not on `git add`.
- `required = true` — if the smudge script is missing or exits non-zero, git
  aborts the checkout entirely. Without this, a missing script silently falls
  back to passing content through unchanged — an undetected bypass.

### How stdin/stdout work

Git pipes the raw file content to the smudge script's stdin. Whatever the
script writes to stdout is what ends up on disk. The canary smudge does this:

```sh
# Log the alert ...
printf '%s\tSMUDGE\t%s@%s\t%s\n' "$TS" "$WHO" "$HOST" "$FILE" >> "$LOG"

# Then pass content through unchanged — file looks completely normal
cat
```

The `cat` at the end is the entire transformation: read stdin, write to stdout.
The file that lands on disk is byte-for-byte identical to what is in the object
store. The attacker sees normal-looking content with no indication the alert fired.

### What triggers smudge — complete list

Any git operation that writes file content from the object store to the working
tree calls the smudge filter. This includes:

| Command | Notes |
|---|---|
| `git checkout <branch>` | All files in the target branch |
| `git checkout -- <file>` | Single file restore (deprecated form) |
| `git restore <file>` | Current preferred form of file restore |
| `git restore --source=<ref> <file>` | Restore from a specific commit |
| `git clone <url>` | The working tree population step at the end |
| `git pull` | Files that changed in the fetched commits |
| `git merge` | Files that changed in the merged branch |
| `git rebase` | Files replayed across commits |
| `git stash pop` | Files restored from the stash |
| `git stash apply` | Same as pop without dropping the stash |
| `git worktree add` | New worktree population |
| `git reset --hard` | Full working tree reset |
| `git read-tree -u` | Low-level tree update |

### What does NOT trigger smudge

| Command | Reason |
|---|---|
| `git show HEAD:<file>` | Reads object to stdout — no working tree write |
| `git cat-file -p <sha>` | Same — direct object read |
| `git ls-files` | Index metadata only |
| `git log` | Commit metadata only |
| `git diff` | Compares object content, no working tree write |
| `cat <file>` | OS read of already-materialised file |
| Any editor open | OS read — git not involved |

### The `required` flag in depth

Without `required = true`:
- Missing smudge script → git silently passes content through (no alert, no error)
- Script exits non-zero → same silent fallback
- An attacker who finds and deletes `canary-smudge` bypasses detection entirely

With `required = true`:
- Missing script → git aborts: `error: external filter ... failed`
- Script exits non-zero → same hard abort
- The file cannot be checked out at all without the script present

This is the right default for a canary system. The trade-off: if the script is
accidentally deleted on a legitimate machine, git checkouts will fail until it
is restored. `setup-canary.sh` handles restoration.

### Long-running filter processes (protocol v2)

Git supports a more efficient filter protocol where a single filter process
handles multiple files without being restarted per file. This is configured with
`process` instead of `smudge`:

```ini
[filter "canary"]
    process  = sh .git/hooks/canary-process
    required = true
```

The process filter implements a packet-line handshake protocol and is more
complex to write. For a canary system processing a small number of decoy files,
the simpler per-file `smudge` form is preferable. The long-running form matters
for repositories with thousands of filtered files (e.g., Git LFS).

### Official documentation

- gitattributes (filters): https://git-scm.com/docs/gitattributes
  — Section: "Filtering Content"
- git-config (filter options): https://git-scm.com/docs/git-config
  — Search: `filter.<driver>`

---

## Part 2 — Sparse Checkout

### What it is

Sparse checkout lets git track files in the index and object store without
materialising them in the working tree. From the git documentation:

> "Sparse checkout allows populating the working directory sparsely. It uses
> the skip-worktree bit to tell Git whether a file in the working directory
> is worth looking at."

For a canary system: honeypot files are committed and tracked (visible via
`git ls-files`, `git log`, `git show`) but the skip-worktree bit is set on
their index entries — so they never appear in `ls` or the filesystem.

### The skip-worktree bit

Each entry in git's index has flags. The skip-worktree bit means:
"I know this file should exist in the working tree, but I am intentionally
not populating it." Git treats the working tree copy as absent even if the
object store has content.

When git needs to materialise a file with skip-worktree set (e.g., via
`git checkout -- decoy/file`), it writes the content to disk and — crucially —
passes it through the smudge filter first. That is the detection moment.

Inspect which files have skip-worktree set:
```bash
git ls-files -v | grep '^S'
# S = skip-worktree, lowercase = normal
```

### Cone mode vs non-cone mode

Sparse checkout has two pattern modes:

**Cone mode (default, git ≥ 2.26)**
- Accepts only directory paths, not arbitrary glob patterns
- Much faster — uses hash-based lookup rather than pattern matching
- Cannot express "include everything except this directory"
- Intended for monorepos where you want a subset of directories

```bash
git sparse-checkout init --cone
git sparse-checkout set real/          # only real/ is on disk
```

**Non-cone mode (deprecated but still works)**
- Uses gitignore-style patterns
- Supports negation: `!/decoy/` means "exclude this path"
- Slower on large repos
- Required for the canary use case — cone mode cannot express exclusions

```bash
git sparse-checkout init --no-cone
# patterns go in .git/info/sparse-checkout
```

The canary system uses non-cone mode specifically because it needs:
```
/*          ← include everything by default
!/decoy/    ← except this directory
```

Cone mode cannot express the second line. The deprecation warning is about
encouraging cone mode for performance — non-cone mode remains functional.

### The sparse-checkout file

`.git/info/sparse-checkout` — plain text, one pattern per line.
Patterns follow gitignore syntax with one inversion: patterns select what
to *include*, not what to exclude (the opposite of `.gitignore`).

Negation patterns (`!`) exclude paths from the working tree.

Example for the canary system:
```
/*
!/decoy/
!*.env
!credentials.*
!*.pem
!*.key
!*_rsa
!*password*
!*secret*
```

Line order matters. Later lines take precedence over earlier ones.

### Key commands

```bash
# Initialise sparse checkout (non-cone for canary use)
git sparse-checkout init --no-cone

# View current patterns
git sparse-checkout list

# Reapply patterns after editing the file manually
git sparse-checkout reapply

# Disable sparse checkout — all files return to working tree
git sparse-checkout disable
```

### Interaction with smudge filters

When `git sparse-checkout reapply` or `git checkout` materialises a file that
was previously excluded (skip-worktree set), git writes it through the smudge
filter before landing it on disk. This is the trigger point.

When `git sparse-checkout reapply` removes a file (re-applies the exclusion),
the clean filter does NOT fire — the file is simply deleted from the working
tree. Only materialisation (object store → disk) triggers smudge.

### Behaviour across git commands in sparse mode

From the git documentation — commands behave differently in sparse mode:

| Behaviour | Command |
|---|---|
| Does not update paths outside sparse patterns | `git switch`, `git checkout <branch>` |
| Does not record outside paths as deleted | `git commit -a` |
| Respects skip-worktree on restore | `git restore` |
| Ignores sparse patterns when forced | `git checkout -f` |
| Re-populates all files | `git sparse-checkout disable` |

### Official documentation

- git-sparse-checkout (command): https://git-scm.com/docs/git-sparse-checkout
- git-read-tree (skip-worktree internals): https://git-scm.com/docs/git-read-tree
  — Section: "Sparse Checkout"
- gitignore (pattern syntax used by non-cone mode): https://git-scm.com/docs/gitignore

---

## Part 3 — How Smudge and Sparse Checkout Interact in This System

```
git commit decoy/aws-credentials
       │
       ▼
  object store ← file exists here, full content
  index entry  ← skip-worktree bit SET (sparse-checkout excluded it)
  working tree ← file does NOT exist here
       │
       │  attacker runs: git checkout -- decoy/aws-credentials
       │
       ▼
  git sees skip-worktree = set, but explicit checkout requested
  git reads blob from object store
       │
       ▼
  [canary-smudge %f]
  ├── logs SMUDGE to .git/canary/access.log
  ├── dispatches to GitHub Actions
  └── passes content through via cat
       │
       ▼
  file written to disk  ← attacker sees normal-looking credentials
  skip-worktree bit CLEARED ← file is now "live" in working tree
```

The attacker gets the file. That is intentional — the deception continues.
The smudge filter fires silently and the file looks exactly as expected.

