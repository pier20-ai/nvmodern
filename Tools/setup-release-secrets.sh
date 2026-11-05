#!/usr/bin/env bash
# One-time setup for .github/workflows/release.yml: stores the signing, notarization
# and update keys as GitHub Actions secrets, and writes the update key's public half
# to Tools/release.env (commit that file). Run it yourself, in Terminal: it asks for
# passwords, and nothing secret it reads is printed or kept on disk.
#
# Usage: Tools/setup-release-secrets.sh <DeveloperID.p12> [--repo owner/name] [--skip-sparkle]
#
#   DeveloperID.p12  the "Developer ID Application" certificate with its private key,
#                    exported from Keychain Access (login › My Certificates › the
#                    identity › Export…, with a password).
#   The update key:  Sparkle's generate_keys keeps it in this Mac's login keychain under
#                    the account "nvmodern" (made on first run, reused after). Not the
#                    default "ed25519" account: other apps on this Mac may use that one.
#                    Back the key up; a lost key means existing installs can't update.
#
# Needs the GitHub CLI (gh) signed in with admin access to the repo, and a prior
# `make` (which fetches Sparkle and its generate_keys tool).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACCOUNT="nvmodern"

P12=""; REPO="pier20-ai/nvmodern"; SPARKLE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --skip-sparkle) SPARKLE=0; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) P12="$1"; shift ;;
  esac
done
[ -f "$P12" ] || { echo "usage: $0 <DeveloperID.p12> [--repo owner/name] [--skip-sparkle]" >&2; exit 2; }
command -v gh >/dev/null || { echo "needs the GitHub CLI (gh), signed in with admin access to $REPO" >&2; exit 1; }
gh repo view "$REPO" >/dev/null || { echo "can't see $REPO with gh" >&2; exit 1; }

if [ "$SPARKLE" = 1 ]; then
  GENKEYS="$(find "$HOME/Library/Developer/Xcode/DerivedData" "$REPO_ROOT/dist/release/DerivedData" \
    -type f -name generate_keys -path '*/sparkle/*' -perm -u+x 2>/dev/null | head -n 1 || true)"
  [ -n "$GENKEYS" ] || { echo "Sparkle's generate_keys not found: run 'make' once first" >&2; exit 1; }
fi

echo "Setting release secrets on $REPO"
ask() { local v; read -r -p "$1: " v; printf '%s' "$v"; }
ask_secret() { local v; read -r -s -p "$1: " v; echo >&2; printf '%s' "$v"; }

P12_PASSWORD="$(ask_secret "Password of $(basename "$P12")")"
# Check the password and that the .p12 holds a Developer ID Application identity.
openssl pkcs12 -in "$P12" -nokeys -passin fd:3 3<<<"$P12_PASSWORD" 2>/dev/null | grep -q "Developer ID Application" \
  || openssl pkcs12 -legacy -in "$P12" -nokeys -passin fd:3 3<<<"$P12_PASSWORD" 2>/dev/null | grep -q "Developer ID Application" \
  || { echo "that .p12 can't be opened with this password, or has no Developer ID Application certificate" >&2; exit 1; }
base64 -i "$P12" | gh secret set DEVELOPER_ID_P12 --repo "$REPO"
printf '%s' "$P12_PASSWORD" | gh secret set DEVELOPER_ID_P12_PASSWORD --repo "$REPO"
unset P12_PASSWORD

echo "Notarization: the Apple ID of the developer account, its team ID, and an app-specific"
echo "password (appleid.apple.com › Sign-In and Security › App-Specific Passwords)."
ask "Apple ID" | gh secret set NOTARY_APPLE_ID --repo "$REPO"
ask "Team ID" | gh secret set NOTARY_TEAM_ID --repo "$REPO"
ask_secret "App-specific password" | gh secret set NOTARY_PASSWORD --repo "$REPO"

if [ "$SPARKLE" = 1 ]; then
  # Makes the key in the login keychain, or reuses it (macOS may ask to allow access).
  "$GENKEYS" --account "$ACCOUNT" >/dev/null
  PUB="$("$GENKEYS" --account "$ACCOUNT" -p)"
  [ -n "$PUB" ] || { echo "generate_keys printed no public key" >&2; exit 1; }
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  (umask 077; "$GENKEYS" --account "$ACCOUNT" -x "$T/key" >/dev/null)
  gh secret set SPARKLE_PRIVATE_KEY --repo "$REPO" < "$T/key"
  rm -f "$T/key"
  cat > "$REPO_ROOT/Tools/release.env" <<EOF
# Public half of nvModern's Sparkle update key (keychain account "$ACCOUNT").
# Written by Tools/setup-release-secrets.sh; Tools/release.sh bakes it into release
# builds only. Source builds keep project.yml's empty key and never check for updates.
SPARKLE_PUBLIC_KEY="$PUB"
EOF
  echo "Update key: public half $PUB, now in Tools/release.env (commit it)."
fi
echo "Done. Secrets on $REPO:"; gh secret list --repo "$REPO"
