#!/usr/bin/env bash
# Repository lint: credentials, Nix formatting and unused arguments,
# Markdown/YAML formatting, Markdown rules and shellcheck over every file
# with a shell shebang (the shebang decides, not the extension).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

# Every file under a secrets/ directory must be sops-encrypted; the
# documented example template is the only allowed plaintext.
while IFS= read -r -d '' f; do
  case "$f" in */secrets.example.yaml) continue ;; esac
  if ! grep -q 'ENC\[AES256_GCM' "$f"; then
    echo "error: $f is not sops-encrypted" >&2
    exit 1
  fi
done < <(find . -name .git -prune -o -type f -path '*/secrets/*' -print0)

gitleaks detect --source . --no-git --no-banner --exit-code 1

mapfile -t nix_files < <(git ls-files -co --exclude-standard '*.nix')
if [ "${#nix_files[@]}" -gt 0 ]; then
  nixfmt --check "${nix_files[@]}"
  deadnix --fail -l -- "${nix_files[@]}"
fi

# No logic in Nix strings: a multi-line shell body belongs in a script file
# (packaged with writeShellApplication or read with builtins.readFile). The
# generated Caddyfile is the one multi-line string of another kind.
if [ "${#nix_files[@]}" -gt 0 ]; then
  inline_shell="$(grep -nE "(^|[^A-Za-z])(script|preStart|postStart|preStop|postStop|preHook|postHook|text|ExecStart(Pre|Post|Stop)?)[[:space:]]*=[[:space:]]*(with [A-Za-z.]+;[[:space:]]*)?''[[:space:]]*$|writeShell(Script|ScriptBin)[^=]*''[[:space:]]*$" "${nix_files[@]}" || true)"
  if [ -n "$inline_shell" ]; then
    echo "error: multi-line shell in Nix strings; move it to a script file:" >&2
    echo "$inline_shell" >&2
    exit 1
  fi
fi

mapfile -t doc_files < <(git ls-files -co --exclude-standard '*.md' '*.yml' '*.yaml' | grep -v '/secrets/')
if [ "${#doc_files[@]}" -gt 0 ]; then
  prettier --check "${doc_files[@]}"
fi
mapfile -t md_files < <(git ls-files -co --exclude-standard '*.md')
if [ "${#md_files[@]}" -gt 0 ]; then
  markdownlint "${md_files[@]}"
fi

mapfile -t shell_files < <(
  git ls-files -co --exclude-standard | while IFS= read -r f; do
    [ -f "$f" ] && head -n1 "$f" | grep -qE '^#!.*\b(sh|bash)\b' && printf '%s\n' "$f"
  done
)
if [ "${#shell_files[@]}" -gt 0 ]; then
  shellcheck --severity=warning -x "${shell_files[@]}"
fi
echo "lint: OK"
