#!/bin/sh
set -e

GIT_DIR=$(git rev-parse --git-dir)

echo "==> Configuring canary system..."

git config core.autocrlf false
git config core.eol lf
git config filter.canary.smudge 'sh .git/hooks/canary-smudge %f'
git config filter.canary.clean  'cat'
git config filter.canary.required true

mkdir -p "$GIT_DIR/canary"

# ── canary-smudge ─────────────────────────────────────────────────────────────
printf '%s\n' \
  '#!/bin/sh' \
  'FILE="$1"' \
  'GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || echo ".git")' \
  'LOG="$GIT_DIR/canary/access.log"' \
  'TS=$(date -u "+%Y-%m-%dT%H:%M:%SZ")' \
  'EVENT="SMUDGE"' \
  'WHO=$(id -un 2>/dev/null)' \
  '[ -z "$WHO" ] && WHO=${USERNAME:-${USER:-unknown}}' \
  'HOST=$(hostname 2>/dev/null || echo "unknown")' \
  'mkdir -p "$GIT_DIR/canary"' \
  'printf "%s\t%s\t%s@%s\t%s\n" "$TS" "$EVENT" "$WHO" "$HOST" "$FILE" >> "$LOG"' \
  'GH_TOKEN=$(git config --get canary.githubToken 2>/dev/null)' \
  'GH_REPO=$(git config --get canary.githubRepo 2>/dev/null)' \
  'if [ -n "$GH_TOKEN" ] && [ -n "$GH_REPO" ]; then' \
  '  PAYLOAD=$(printf '"'"'{"event_type":"canary_triggered","client_payload":{"file":"%s","user":"%s","host":"%s","ts":"%s","event":"%s"}}'"'"' "$FILE" "$WHO" "$HOST" "$TS" "$EVENT")' \
  '  curl -sf -X POST \' \
  '    -H "Authorization: token $GH_TOKEN" \' \
  '    -H "Accept: application/vnd.github.v3+json" \' \
  '    -H "Content-Type: application/json" \' \
  '    -d "$PAYLOAD" \' \
  '    "https://api.github.com/repos/$GH_REPO/dispatches" \' \
  '    >/dev/null 2>&1 &' \
  'fi' \
  'cat' \
  > "$GIT_DIR/hooks/canary-smudge"

# ── post-checkout ─────────────────────────────────────────────────────────────
printf '%s\n' \
  '#!/bin/sh' \
  'PREV="$1"; NEW="$2"; FLAG="$3"' \
  'GIT_DIR=$(git rev-parse --git-dir)' \
  'LOG="$GIT_DIR/canary/access.log"' \
  'TS=$(date -u "+%Y-%m-%dT%H:%M:%SZ")' \
  'WHO=$(id -un 2>/dev/null)' \
  '[ -z "$WHO" ] && WHO=${USERNAME:-${USER:-unknown}}' \
  'HOST=$(hostname 2>/dev/null || echo "unknown")' \
  'mkdir -p "$GIT_DIR/canary"' \
  'if [ "$FLAG" = "1" ]; then' \
  '  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "$NEW")' \
  '  printf "%s\tCHECKOUT-BRANCH\t%s@%s\t%s\n" "$TS" "$WHO" "$HOST" "$BRANCH" >> "$LOG"' \
  '  git ls-files | while read -r F; do' \
  '    ATTR=$(git check-attr filter -- "$F" 2>/dev/null | grep "filter: canary")' \
  '    [ -n "$ATTR" ] && printf "%s\tCANARY-IN-BRANCH\t%s@%s\t%s\n" "$TS" "$WHO" "$HOST" "$F" >> "$LOG"' \
  '  done' \
  'fi' \
  > "$GIT_DIR/hooks/post-checkout"

# ── post-merge ────────────────────────────────────────────────────────────────
printf '%s\n' \
  '#!/bin/sh' \
  'GIT_DIR=$(git rev-parse --git-dir)' \
  'LOG="$GIT_DIR/canary/access.log"' \
  'TS=$(date -u "+%Y-%m-%dT%H:%M:%SZ")' \
  'WHO=$(id -un 2>/dev/null)' \
  '[ -z "$WHO" ] && WHO=${USERNAME:-${USER:-unknown}}' \
  'HOST=$(hostname 2>/dev/null || echo "unknown")' \
  'mkdir -p "$GIT_DIR/canary"' \
  'git diff-tree -r --name-only --no-commit-id ORIG_HEAD HEAD 2>/dev/null | while read -r F; do' \
  '  ATTR=$(git check-attr filter -- "$F" 2>/dev/null | grep "filter: canary")' \
  '  [ -n "$ATTR" ] && printf "%s\tMERGE-PULL\t%s@%s\t%s\n" "$TS" "$WHO" "$HOST" "$F" >> "$LOG"' \
  'done' \
  > "$GIT_DIR/hooks/post-merge"

# ── Permissions ───────────────────────────────────────────────────────────────
case "$(uname -s 2>/dev/null)" in
  Linux|Darwin)
    chmod +x "$GIT_DIR/hooks/canary-smudge"
    chmod +x "$GIT_DIR/hooks/post-checkout"
    chmod +x "$GIT_DIR/hooks/post-merge"
    ;;
esac

# ── Sparse checkout ───────────────────────────────────────────────────────────
git sparse-checkout init --no-cone
printf '/*\n!/decoy/\n!aws-credentials\n!database.env\n!*.pem\n!*.key\n!*_rsa\n!*password*\n!*secret*\n!credentials.*\n' \
  > "$GIT_DIR/info/sparse-checkout"
git sparse-checkout reapply

# ── GitHub alerting ───────────────────────────────────────────────────────────
echo ""
echo "==> GitHub alerting (press Enter to skip):"
printf "    GitHub PAT (repo scope): "
read GH_TOKEN
if [ -n "$GH_TOKEN" ]; then
  printf "    GitHub repo (owner/repo): "
  read GH_REPO
  git config canary.githubToken "$GH_TOKEN"
  git config canary.githubRepo  "$GH_REPO"
  echo "    Configured."
else
  echo "    Skipped — add later:"
  echo "      git config canary.githubToken 'ghp_...'"
  echo "      git config canary.githubRepo  'owner/repo'"
fi

echo ""
echo "==> Done. Test with:"
echo "    git add --sparse decoy/ && git commit -m 'Add decoy files'"
echo "    git checkout -- decoy/aws-credentials"
echo "    cat $GIT_DIR/canary/access.log"
