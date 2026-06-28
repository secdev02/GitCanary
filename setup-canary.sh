cat > setup-canary.sh << 'SETUP'
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

# ── Write canary-smudge ───────────────────────────────────────────────────────
cat > "$GIT_DIR/hooks/canary-smudge" << 'HOOK'
#!/bin/sh
FILE="$1"
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || echo '.git')
LOG="$GIT_DIR/canary/access.log"
TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EVENT="SMUDGE"
WHO=$(id -un 2>/dev/null)
[ -z "$WHO" ] && WHO=${USERNAME:-${USER:-unknown}}
HOST=$(hostname 2>/dev/null || echo 'unknown')
mkdir -p "$GIT_DIR/canary"
printf '%s\t%s\t%s@%s\t%s\n' "$TS" "$EVENT" "$WHO" "$HOST" "$FILE" >> "$LOG"
GH_TOKEN=$(git config --get canary.githubToken 2>/dev/null)
GH_REPO=$(git config --get canary.githubRepo   2>/dev/null)
if [ -n "$GH_TOKEN" ] && [ -n "$GH_REPO" ]; then
  PAYLOAD=$(printf \
    '{"event_type":"canary_triggered","client_payload":{"file":"%s","user":"%s","host":"%s","ts":"%s","event":"%s"}}' \
    "$FILE" "$WHO" "$HOST" "$TS" "$EVENT")
  curl -sf -X POST \
    -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
