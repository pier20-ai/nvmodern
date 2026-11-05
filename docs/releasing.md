# Releasing and auto-update

nvModern updates itself with [Sparkle](https://sparkle-project.org). Releases
live on GitHub Releases; the app checks `appcast.xml`, attached to the latest
release, at

    https://github.com/pier20-ai/nvmodern/releases/latest/download/appcast.xml

Sparkle downloads the DMG, verifies its EdDSA signature against the public key
baked into the app, checks the Developer ID code signature, replaces the app
and relaunches. Users get **nvModern > Check for Updates…** and a toggle under
**Settings > General > Updates**.

## Source builds do not update

`AppUpdater` starts Sparkle only when the build has both `SUFeedURL` and a
non-empty `SUPublicEDKey`. In `project.yml`, `SPARKLE_PUBLIC_ED_KEY` is empty, so
`make run` and builds from forks never contact GitHub and show no update UI.
Release builds get the key from `Tools/release.env`, which only `Tools/release.sh`
reads. Forks that want their own updates generate their own key and change `SUFeedURL`.

## Cutting a release

Releases are built by GitHub Actions
([`.github/workflows/release.yml`](../.github/workflows/release.yml)) on a
GitHub-hosted Mac (`macos-26`):

1. Make sure `main` is clean and tests pass: `make test` and `make test-web`.
2. Tag and push: `git tag v2.1.0 && git push origin main v2.1.0`. The tag is
   the version: `v2.1.0` builds `MARKETING_VERSION` 2.1.0.
3. The workflow imports the Developer ID into a temporary keychain and runs
   `make release`. That builds the app, signs it, notarizes and staples the app
   and the DMG, writes the signed `appcast.xml` and the SHA-256 checksums. Then
   the workflow creates a **draft** release with `nvModern-2.1.0.dmg`,
   `nvModern.dmg` (a stable-named copy, so `releases/latest/download/nvModern.dmg`
   links never change), `nvModern-2.1.0.sha256` and `appcast.xml`. Build logs
   are attached to the run as the `release-logs` artifact.
4. Smoke-test the DMG from the draft: mount it, drag the app out, launch it, and
   check that **nvModern > Check for Updates…** is there.
5. **Publish** the draft. Only then do installed apps see the update:
   `releases/latest` ignores drafts and pre-releases.

`appcast.xml` points at `releases/download/v<version>/nvModern-<version>.dmg`,
so the tag must be `v<version>`, and the DMG and the appcast must be on the same
release.

### Secrets

The workflow needs these repository secrets. Run
`Tools/setup-release-secrets.sh <DeveloperID.p12>` yourself in Terminal to set
them: it prompts for the passwords and never prints them.

| secret | what |
|---|---|
| `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD` | the "Developer ID Application" certificate and private key, exported from Keychain Access (login › My Certificates › Export…) as a .p12 with a password |
| `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` | the developer account's Apple ID, team ID, and an app-specific password (appleid.apple.com › Sign-In and Security › App-Specific Passwords) |
| `SPARKLE_PRIVATE_KEY` | nvModern's update signing key |

The script needs `gh` signed in with admin access to the repo, and a prior
`make` (which fetches Sparkle's `generate_keys`). It creates the update key, or
reuses it, in the login keychain under the account **`nvmodern`**, never the
default `ed25519` account, which other apps on the same Mac may use. It stores
the private half as `SPARKLE_PRIVATE_KEY` and writes the public half to
`Tools/release.env`. **Commit `Tools/release.env`.** The workflow refuses to run
without it.

Back up the private key (`generate_keys --account nvmodern -x private.key`, kept
in a password manager). **If you lose it, existing installs cannot be updated**,
and users must reinstall by hand.

The update feed and download links only work for users when the GitHub repo is
public. On a private repo, `releases/latest/download/...` needs a login.

## Releasing locally

`make release` does the same build on a Mac whose login keychain has the
Developer ID identity, a notarytool profile and the `nvmodern` update key:

```sh
xcrun notarytool store-credentials nvmodern-notary \
  --apple-id you@example.com --team-id TEAMID
make release VERSION=2.1.0 \
  DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
  NOTARY_PROFILE=nvmodern-notary
```

Artifacts land in `dist/release/upload/`. The script never publishes; it prints
the `gh release create --draft` command to run.

## Versioning

- `MARKETING_VERSION` (shown to users) comes from `VERSION`.
- `CFBundleVersion` is a UTC `yymmddHHMM` timestamp set at release time. Sparkle
  compares it, so it must always increase; it does not depend on git history.
- Source builds keep `CURRENT_PROJECT_VERSION: 0`.

## Signing notes

- The script builds unsigned, embeds the `nv3` CLI, then signs inside-out:
  Sparkle's helpers and framework, `nv3`, then the app, all with the hardened
  runtime. Signing before embedding `nv3` would invalidate the signature.
- The app is notarized and stapled before it goes into the DMG, so it passes
  Gatekeeper offline, including after Sparkle installs it. The DMG is then
  notarized and stapled too.
- `Tools/release.sh` takes `NOTARY_KEYCHAIN` when the notarytool profile lives
  outside the login keychain (the workflow's temporary keychain), and
  `SPARKLE_PRIVATE_KEY` (the exported key) instead of the keychain item.
- The app has no entitlements and is not sandboxed. JavaScriptCore (plugins)
  runs without JIT under the hardened runtime, which is fine for plugin
  workloads. If a feature needs JIT, add `com.apple.security.cs.allow-jit`.
- Test an update end to end by installing an older signed build, publishing a
  newer draft-free test release to a private fork, and pointing `SUFeedURL` at it.

## Testing the updater UI locally

Build with a throwaway key and a local feed to see the menu item and Settings
section:

```sh
make SPARKLE_PUBLIC_ED_KEY=test-key-only
```

The check will fail signature verification, which is the point: only a build
signed with your real key can install updates.
