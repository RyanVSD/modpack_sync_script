#!/bin/bash
cd "${SERVER_ROOT:~/home/container" || exit 1

log() { echo "[sync] $*"; }
warn() { echo "[sync] WARNING: $*" >&2; }

REPO="${GITHUB_REPO:-}"
BRANCH="${GITHUB_BRANCH:-main}"
MIRROR="${SYNC_MIRROR:-mods config}"
SKIP=".git .github .gitignore .gitattributes README.md LICENSE LICENSE.md sync.sh"

[-z "$REPO"] && {log "GITHUB_REPO not set"; exit 0; }

REPO="${REPO#https://github.com/}"; REPO="${REPO#http://github.com/}"
REPO="${REPO%/}"; REPO="${REPO%.git}"
[[ "$REPO"   =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { warn "GITHUB_REPO must be owner/name or a github.com URL (got '$GITHUB_REPO'), skipping"; exit 0; }
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]]                || { warn "invalid GITHUB_BRANCH, skipping"; exit 0; }

auth=()
[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
API="https://api.github.com/repos/${REPO}"

remote_sha="$(curl -fsSL --retry 2 --max-time 20 "${auth[@]}" -H 'Accept: application/vnd.github.sha' "${API}/commits/${BRANCH}")"
if [[ ! "$remote_sha" =~ ^[0-9a-f]{40}$ ]]; then
  warn "could not check ${REPO}@${BRANCH} (private repo without token? wrong name/branch? offline?); using existing files"
  exit 0
fi
if [ "$(cat .sync_sha 2>/dev/null)" = "$remote_sha" ] && [ -d mods ]; then
  log "already up to date (${remote_sha:0:7})"
  exit 0
fi

# download
log "updating to ${REPO}@${BRANCH} (${remote_sha:0:7})"
rm -rf .sync.new && mkdir -p .sync.new
if ! curl -fsSL --retry 3 --max-time 900 "${auth[@]}" "${API}/tarball/${remote_sha}" | tar -xz -C .sync.new --strip-components=1; then
  rm -rf .sync.new
  warn "download failed; using existing files"
  exit 0
fi

# sync
shopt -s dotglob nullglob
for src in .sync.new/*; do
  name="$(basename "$src")"
  case " $SKIP " in *" $name "*) continue ;; esac
  case "$name" in .sync*|world|eula.txt|server.properties) continue ;; esac   # never touch these (Wings manages the port in server.properties)

  if [ -d "$src" ] && [[ " $MIRROR " == *" $name "* ]]; then
    rm -rf ".sync.swap-$name" && cp -a "$src" ".sync.swap-$name" \
      && rm -rf "./$name" && mv ".sync.swap-$name" "./$name"
    log "mirrored $name/"
  elif [ -d "$src" ]; then
    mkdir -p "./$name" && cp -a "$src"/. "./$name"/
    log "overlaid $name/"
  else
    cp -af "$src" "./$name"
    log "copied $name"
  fi
done
shopt -u dotglob nullglob

# cleanup 
rm -rf .sync.new
echo "$remote_sha" > .sync_sha
log "done"
exit 0

