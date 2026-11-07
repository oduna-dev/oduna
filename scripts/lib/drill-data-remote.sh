#!/usr/bin/env bash
# Host-side half of drill-data.sh, streamed over SSH and run as root.
#
# Environment: MODE (seed|verify), INTERNAL_DOMAIN, FORGEJO_ENABLED,
# IMMICH_ENABLED, FORGEJO_PORT, MANIFEST (JSON, verify only); ADMIN_ENV_FILE overrides the sops path of the
# shared admin identity.
set -euo pipefail

: "${MODE:?}" "${INTERNAL_DOMAIN:?}" "${FORGEJO_PORT:?}"
admin_env="${ADMIN_ENV_FILE:-/run/secrets/admin.env}"
admin_email="$(sed -n 's/^ADMIN_EMAIL=//p' "$admin_env")"
admin_password="$(sed -n 's/^ADMIN_PASSWORD=//p' "$admin_env")"
admin_user="${admin_email%%@*}"
[ -n "$admin_email" ] && [ -n "$admin_password" ] || {
  echo "admin identity not readable from $admin_env" >&2
  exit 1
}

failures=0
ok() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}

forgejo_url="http://127.0.0.1:$FORGEJO_PORT/api/v1"
fj() { curl -fsS -u "$admin_user:$admin_password" -H 'Content-Type: application/json' "$@"; }
immich_url="https://immich.$INTERNAL_DOMAIN/api"
immich_token() {
  curl -fsS -X POST "$immich_url/auth/login" -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg e "$admin_email" --arg p "$admin_password" '{email: $e, password: $p}')" \
    | jq -r '.accessToken'
}

# A 16x16 red JPEG; the content hash is the same on every host.
photo_b64='/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAAQABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDl6KKK8c/Rz//Z'

seed_forgejo() {
  local repo=drill-seed
  fj -X POST "$forgejo_url/user/repos" \
    -d "$(jq -cn --arg n "$repo" '{name: $n, private: true, auto_init: false}')" >/dev/null
  local content1 content2
  content1="$(printf 'first commit %s\n' "$(date -u +%FT%TZ)" | base64 -w0)"
  fj -X POST "$forgejo_url/repos/$admin_user/$repo/contents/README.md" \
    -d "$(jq -cn --arg c "$content1" '{content: $c, message: "Seed: first commit"}')" >/dev/null
  content2="$(printf 'second file\n' | base64 -w0)"
  fj -X POST "$forgejo_url/repos/$admin_user/$repo/contents/notes.txt" \
    -d "$(jq -cn --arg c "$content2" '{content: $c, message: "Seed: second commit"}')" >/dev/null
  fj "$forgejo_url/repos/$admin_user/$repo/commits?limit=1" \
    | jq -c --arg r "$admin_user/$repo" '{repo: $r, head: .[0].sha}'
}

verify_forgejo() {
  local repo head live
  repo="$(jq -r '.forgejo.repo' <<<"$MANIFEST")"
  head="$(jq -r '.forgejo.head' <<<"$MANIFEST")"
  live="$(fj "$forgejo_url/repos/$repo/commits?limit=1" | jq -r '.[0].sha')" || live=""
  if [ "$live" = "$head" ]; then
    ok "forgejo: $repo is back at $head"
  else
    fail "forgejo: $repo head is '${live:-missing}', expected $head"
  fi
  if [ "$(fj "$forgejo_url/repos/$repo/commits?limit=10" | jq 'length')" = "2" ]; then
    ok "forgejo: history has both seed commits"
  else
    fail "forgejo: history does not have two commits"
  fi
}

seed_immich() {
  local token tmp resp
  token="$(immich_token)"
  tmp="$(mktemp)"
  printf '%s' "$photo_b64" | base64 -d >"$tmp"
  resp="$(curl -fsS -X POST "$immich_url/assets" -H "Authorization: Bearer $token" \
    -F deviceAssetId="drill-seed-photo" -F deviceId=drill-seed \
    -F fileCreatedAt="2020-01-01T00:00:00.000Z" -F fileModifiedAt="2020-01-01T00:00:00.000Z" \
    -F "assetData=@$tmp;filename=drill-seed.jpg")"
  rm -f "$tmp"
  jq -c --arg sum "$(printf '%s' "$photo_b64" | base64 -d | sha256sum | cut -d' ' -f1)" \
    '{asset: .id, sha256: $sum}' <<<"$resp"
}

verify_immich() {
  local id sum token live
  id="$(jq -r '.immich.asset' <<<"$MANIFEST")"
  sum="$(jq -r '.immich.sha256' <<<"$MANIFEST")"
  token="$(immich_token)" || token=""
  [ -n "$token" ] || {
    fail "immich: admin login failed"
    return
  }
  if curl -fsS -H "Authorization: Bearer $token" "$immich_url/assets/$id" >/dev/null; then
    ok "immich: asset $id is in the library"
  else
    fail "immich: asset $id is missing"
    return
  fi
  live="$(curl -fsS -H "Authorization: Bearer $token" "$immich_url/assets/$id/original" | sha256sum | cut -d' ' -f1)" || live=""
  if [ "$live" = "$sum" ]; then
    ok "immich: original file is byte-identical"
  else
    fail "immich: original file differs or is unreadable"
  fi
}

# Progress goes to stderr; seed prints the manifest on stdout.
case "$MODE" in
  seed)
    entries='{}'
    if [ "${FORGEJO_ENABLED:-false}" = "true" ]; then
      entries="$(jq -c --argjson v "$(seed_forgejo)" '.forgejo = $v' <<<"$entries")"
      ok "forgejo: seeded" >&2
    fi
    if [ "${IMMICH_ENABLED:-false}" = "true" ]; then
      entries="$(jq -c --argjson v "$(seed_immich)" '.immich = $v' <<<"$entries")"
      ok "immich: seeded" >&2
    fi
    printf '%s\n' "$entries"
    ;;
  verify)
    : "${MANIFEST:?}"
    jq -e 'has("forgejo")' <<<"$MANIFEST" >/dev/null && verify_forgejo
    jq -e 'has("immich")' <<<"$MANIFEST" >/dev/null && verify_immich
    if [ "$failures" -gt 0 ]; then
      echo "$failures check(s) failed" >&2
      exit 1
    fi
    echo "all seeded data present"
    ;;
esac
