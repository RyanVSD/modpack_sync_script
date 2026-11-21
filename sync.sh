#!/bin/bash
cd "${SERVER_ROOT:-/home/container}" || exit 1

log() { echo "[sync] $*"; }
warn() { echo "[sync] WARNING: $*" >&2; }

REPO="${GITHUB_REPO:-}"
BRANCH="${GITHUB_BRANCH:-main}"
MIRROR="${SYNC_MIRROR:-mods config}"
SIDE="${PACKWIZ_SIDE:-server}"
SKIP=".git .github .gitignore .gitattributes README.md LICENSE LICENSE.md sync.sh"
BOOTSTRAP_URL="https://github.com/packwiz/packwiz-installer-bootstrap/releases/latest/download/packwiz-installer-bootstrap.jar"

[ -z "$REPO"] && { log "GITHUB_REPO not set"; exit 0; }

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

# check for packwiz.toml at root
code="$(curl -sSL --max-time 20 "${auth[@]}" -H 'Accept: application/vnd.github.raw' \
        -o /dev/null -w '%{http_code}' "${API}/contents/pack.toml?ref=${remote_sha}")"
case "$code" in
  200) MODE="packwiz" ;;
  404) MODE="jar" ;;
  *)   warn "could not inspect repo contents (HTTP ${code:-none}); using existing files"; exit 0 ;;
esac
log "${REPO}@${BRANCH} (${remote_sha:0:7}) -> ${MODE} mode"

# switching modes: old mods aren't tracked by the new mode, so start clean to avoid duplicates
prev_mode="$(cat .sync_mode 2>/dev/null)"
if [ -n "$prev_mode" ] && [ "$prev_mode" != "$MODE" ]; then
  warn "mode changed (${prev_mode} -> ${MODE}); clearing mods/ and packwiz state"
  rm -rf mods packwiz.json
fi
code="$(curl -sSL --max-time 20 "${auth[@]}" -H 'Accept: application/vnd.github.raw' \
        -o /dev/null -w '%{http_code}' "${API}/contents/pack.toml?ref=${remote_sha}")"

case "$code" in
  200) MODE="packwiz" ;;
  404) MODE="jar" ;;
  *)   warn "could not inspect repo contents (HTTP ${code:-none}); using existing files"; exit 0 ;;
esac
log "${REPO}@${BRANCH} (${remote_sha:0:7}) -> ${MODE} mode"

# download via packwiz
if [ "$MODE" = "packwiz" ]; then
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    warn "packwiz mode downloads via public raw URLs; the token is not used, so the repo must be public"
  fi
  if [ ! -s packwiz-installer-bootstrap.jar ]; then
    log "downloading packwiz-installer-bootstrap"
    if ! curl -fsSL --retry 3 --max-time 120 "$BOOTSTRAP_URL" -o .bootstrap.tmp; then
      rm -f .bootstrap.tmp; warn "could not download packwiz-installer-bootstrap; using existing files"; exit 0
    fi
    mv .bootstrap.tmp packwiz-installer-bootstrap.jar
  fi
  # pinned to the commit so a stale branch cache can't give a half-updated pack
  PACK_URL="https://raw.githubusercontent.com/${REPO}/${remote_sha}/pack.toml"
  log "running packwiz-installer (side: ${SIDE})"
  if java -jar packwiz-installer-bootstrap.jar -g -s "$SIDE" "$PACK_URL"; then
    echo "$remote_sha" > .sync_sha
    echo "packwiz" > .sync_mode
    log "done"
  else
    warn "packwiz-installer failed (see output above; a CurseForge mod that blocks third-party downloads is a common cause); will retry next boot"
  fi
  exit 0
fi

# download via jars
log "downloading repo"
rm -rf .sync.new && mkdir -p .sync.new
if ! curl -fsSL --retry 3 --max-time 900 "${auth[@]}" "${API}/tarball/${remote_sha}" | tar -xz -C .sync.new --strip-components=1; then
  rm -rf .sync.new
  warn "download failed; using existing files"
  exit 0
fi

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
echo "jar" > .sync_mode
log "done"
exit 0

