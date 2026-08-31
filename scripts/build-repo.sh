#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/config.sh"

STANZA_DIR="$ROOT/metadata/stanzas"
OUT="$ROOT/public"
DIST_DIR="$OUT/dists/$SUITE"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v gh             >/dev/null || die "missing 'gh' (GitHub CLI)"
command -v jq             >/dev/null || die "missing 'jq'"
command -v dpkg-deb       >/dev/null || die "missing 'dpkg-deb' (dpkg-dev)"
command -v apt-ftparchive >/dev/null || die "missing 'apt-ftparchive' (apt-utils)"

mkdir -p "$STANZA_DIR" "$DIST_DIR"

log "Querying $UPSTREAM_REPO releases (newest $KEEP_RELEASES)"
RELEASES="$(
  gh api "repos/$UPSTREAM_REPO/releases?per_page=100" \
  | jq -r --argjson limit "$KEEP_RELEASES" --arg pkg "$PACKAGE" --arg arches "${ARCHES[*]}" '
      ($arches | split(" ")) as $want
      | [ .[]
          | select(.draft | not)
          | { tag: .tag_name,
              published: .published_at,
              assets: [ .assets[]
                | select(.name | startswith($pkg + "_"))
                | select(.name | endswith(".deb"))
                | { name: .name,
                    size: .size,
                    url: .browser_download_url,
                    arch: (.name | capture("_(?<a>[a-z0-9]+)\\.deb$").a) }
                | select([.arch] | inside($want)) ] }
          | select(.assets | length > 0) ]
      | sort_by(.published) | reverse | .[0:$limit]
      | .[] as $r | $r.assets[]
      | [$r.tag, .name, .arch, (.size | tostring), .url] | @tsv'
)"
[[ -n "$RELEASES" ]] || die "no release exposes a $PACKAGE .deb"

LATEST_TAG="$(head -1 <<<"$RELEASES" | cut -f1)"
log "Latest version: $LATEST_TAG"

while IFS=$'\t' read -r tag name arch size url; do
  stanza="$STANZA_DIR/${name%.deb}.stanza"
  [[ -s "$stanza" ]] && continue

  log "New: $name ($(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "$size B")) — downloading to hash it"
  deb="$WORK/$name"
  curl -fL --retry 3 --retry-delay 5 --progress-bar -o "$deb" "$url"

  real_size="$(stat -c%s "$deb")"
  [[ "$real_size" == "$size" ]] \
    || log "warning: real size ($real_size) differs from the API's ($size); using the real one"

  {
    dpkg-deb --field "$deb"
    printf 'Filename: %s/%s\n' "$POOL_DIR" "$name"
    printf 'Size: %s\n'   "$real_size"
    printf 'MD5sum: %s\n' "$(md5sum    "$deb" | cut -d' ' -f1)"
    printf 'SHA1: %s\n'   "$(sha1sum   "$deb" | cut -d' ' -f1)"
    printf 'SHA256: %s\n' "$(sha256sum "$deb" | cut -d' ' -f1)"
  } > "$stanza"

  rm -f "$deb"
done <<<"$RELEASES"

while IFS= read -r cached; do
  base="$(basename "$cached" .stanza)"
  grep -qF "	${base}.deb	" <<<"$RELEASES" && continue
  log "Dropping stale version: $base"
  rm -f "$cached"
done < <(find "$STANZA_DIR" -name '*.stanza' -type f)

for arch in "${ARCHES[@]}"; do
  dir="$DIST_DIR/$COMPONENT/binary-$arch"
  mkdir -p "$dir"
  : > "$dir/Packages"
  first=1
  while IFS=$'\t' read -r tag name a size url; do
    [[ "$a" == "$arch" ]] || continue
    (( first )) || printf '\n' >> "$dir/Packages"
    cat "$STANZA_DIR/${name%.deb}.stanza" >> "$dir/Packages"
    first=0
  done <<<"$RELEASES"
  gzip -9nc "$dir/Packages" > "$dir/Packages.gz"
  log "$COMPONENT/binary-$arch: $(grep -c '^Package: ' "$dir/Packages") versions"
done

rm -f "$DIST_DIR/Release" "$DIST_DIR/Release.gpg" "$DIST_DIR/InRelease"
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin="$ORIGIN" \
  -o APT::FTPArchive::Release::Label="$LABEL" \
  -o APT::FTPArchive::Release::Suite="$SUITE" \
  -o APT::FTPArchive::Release::Codename="$SUITE" \
  -o APT::FTPArchive::Release::Architectures="${ARCHES[*]}" \
  -o APT::FTPArchive::Release::Components="$COMPONENT" \
  -o APT::FTPArchive::Release::Description="$RELEASE_DESCRIPTION" \
  release "$DIST_DIR" > "$WORK/Release"
mv "$WORK/Release" "$DIST_DIR/Release"

if [[ "${SKIP_SIGN:-0}" == 1 ]]; then
  log "SKIP_SIGN=1: repository left UNSIGNED"
else
  if [[ -z "$GPG_KEY_ID" ]]; then
    GPG_KEY_ID="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"
    [[ -n "$GPG_KEY_ID" ]] || die "no secret key in the keyring; run the bootstrap-key workflow"
  fi

  gpg_args=(--batch --yes --armor --pinentry-mode loopback --local-user "$GPG_KEY_ID")
  [[ -n "${GPG_PASSPHRASE:-}" ]] && gpg_args+=(--passphrase "$GPG_PASSPHRASE")

  gpg "${gpg_args[@]}" --clearsign   -o "$DIST_DIR/InRelease"   "$DIST_DIR/Release"
  gpg "${gpg_args[@]}" --detach-sign -o "$DIST_DIR/Release.gpg" "$DIST_DIR/Release"

  gpg --export "$GPG_KEY_ID" > "$OUT/$KEYRING_NAME"
  [[ -s "$OUT/$KEYRING_NAME" ]] || die "public key export came out empty"
  log "Signed with $GPG_KEY_ID"
fi

while IFS=$'\t' read -r tag name arch size url; do
  printf '/%s/%s %s 302\n' "$POOL_DIR" "$name" "$url"
done <<<"$RELEASES" > "$OUT/_redirects"
log "_redirects: $(wc -l < "$OUT/_redirects") rules"

DEB_VERSION="$(awk '/^Version: /{print $2; exit}' "$DIST_DIR/$COMPONENT/binary-${ARCHES[0]}/Packages")"
REPO_HOST="${REPO_URL#*://}"; REPO_HOST="${REPO_HOST%%/*}"

sed \
  -e "s|{{VERSION}}|$DEB_VERSION|g" \
  -e "s|{{TAG}}|$LATEST_TAG|g" \
  -e "s|{{REPO_URL}}|${REPO_URL%/}|g" \
  -e "s|{{REPO_HOST}}|$REPO_HOST|g" \
  -e "s|{{UPSTREAM_REPO}}|$UPSTREAM_REPO|g" \
  -e "s|{{PACKAGE}}|$PACKAGE|g" \
  -e "s|{{KEYRING_NAME}}|$KEYRING_NAME|g" \
  -e "s|{{SUITE}}|$SUITE|g" \
  -e "s|{{COMPONENT}}|$COMPONENT|g" \
  -e "s|{{ARCHES}}|${ARCHES[*]}|g" \
  -e "s|{{UPDATED}}|$(date -u '+%Y-%m-%d %H:%M UTC')|g" \
  "$ROOT/templates/index.html.tmpl" > "$OUT/index.html"

log "Done. Publishable root: $OUT (version $DEB_VERSION)"
