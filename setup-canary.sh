#!/bin/sh
# setup-canary.sh
# Run once per machine after cloning. Works from Git Bash on Windows,
# bash on Linux / macOS.
set -e

GIT_DIR=$(git rev-parse --git-dir)
REPO_ROOT=$(git rev-parse --show-toplevel)

echo "==> Configuring canary system..."

# ── Prevent CRLF corruption of hook scripts on Windows ───────────────────────
git config core.autocrlf false
git config core.eol lf

# ── Register the canary smudge filter ────────────────────────────────────────
# explicit 'sh' invocation makes the path reliable on all platforms,
# including Windows where a bare script path may not be recognised
git config filter.canary.smudge 'sh .git/hooks/canary-smudge %f'
git config filter.canary.clean  'cat'
git config filter.canary.required true

# ── Copy hooks into .git/hooks/ ───────────────────────────────────────────────
cp "$REPO_ROOT/hooks/canary-smudge"  "$GIT_DIR/hooks/canary-smudge"
cp "$REPO_ROOT/hooks/post-checkout"  "$GIT_DIR/hooks/post-checkout"
cp "$REPO_ROOT/hooks/post-merge"     "$GIT_DIR/hooks/post-merge"

# ── Make hooks executable on Linux / macOS (no-op on Windows) ────────────────
case "$(uname -s 2>/dev/null)" in
  Linux|Darwin)
    chmod +x "$GIT_DIR/hooks/canary-smudge"
    chmod +x "$GIT_DIR/hooks/post-checkout"
    chmod +x "$GIT_DIR/hooks/post-merge"
    ;;
esac

# ── Create log directory ──────────────────────────────────────────────────────
mkdir -p "$GIT_DIR/canary"

# ── Sparse checkout: real/ on disk, decoy/ and canary patterns excluded ───────
# non-cone mode required — cone mode cannot express exclusion patterns
git sparse-checkout init --no-cone

cat > "$GIT_DIR/info/sparse-checkout" << 'SPARSE'
/*
!/decoy/
!aws-credentials
!database.env
!*.pem
!*.key
!*_rsa
!*password*
!*secret*
!credentials.*
SPARSE

git sparse-checkout reapply

# ── Prompt for GitHub alerting (optional) ─────────────────────────────────────
echo ""
echo "==> GitHub alerting (optional — press Enter to skip):"
printf   "    GitHub PAT (repo scope): "
read GH_TOKEN
if [ -n "$GH_TOKEN" ]; then
  printf "    GitHub repo (owner/repo): "
  read GH_REPO
  git config canary.githubToken "$GH_TOKEN"
  git config canary.githubRepo  "$GH_REPO"
  echo "    GitHub alerting configured."
else
  echo "    Skipped. Configure later with:"
  echo "      git config canary.githubToken 'ghp_...'"
  echo "      git config canary.githubRepo  'owner/repo'"
fi

echo ""
echo "==> Canary active."
echo "    Log:           $GIT_DIR/canary/access.log"
echo "    Sparse config: $GIT_DIR/info/sparse-checkout"
echo ""
echo "    Test: git checkout -- decoy/aws-credentials"
echo "          cat $GIT_DIR/canary/access.log"
