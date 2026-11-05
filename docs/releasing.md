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
`make release` passes the real key on the command line. Forks that want their own
updates generate their own key and change `SUFeedURL`.

## One-time setup (maintainer)

1. **Developer ID.** Install a *Developer ID Application* certificate in your
   login keychain. List it with `security find-identity -v -p codesigning`.
2. **Notary profile.** Store notarization credentials once:

   ```sh
   xcrun notarytool store-credentials nvmodern-notary \
     --apple-id you@example.com --team-id TEAMID
   ```

3. **Sparkle signing key.** After a first `make` (which fetches Sparkle), run its
   key tool. It creates the private key in your login keychain and prints the
   public key:

   ```sh
   find ~/Library/Developer/Xcode/DerivedData -name generate_keys -path '*sparkle*' | head -1
   <that path>/generate_keys
   ```

   Back up the private key (`generate_keys -x private.key`) in a password
   manager. **If you lose it, existing installs cannot be updated** and users
   must reinstall manually.

## Cutting a release

1. Make sure `main` is clean and tests pass: `make test` and `make test-web`.
2. Build, sign, notarize and generate the appcast:

   ```sh
   make release VERSION=2.1.0 \
     DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
     NOTARY_PROFILE=nvmodern-notary \
     SPARKLE_PUBLIC_KEY=<public key from generate_keys>
   ```

   Artifacts land in `dist/release/upload/`: `nvModern-2.1.0.dmg`, a
   stable-named copy `nvModern.dmg` (so README and website links like
   `releases/latest/download/nvModern.dmg` never change), and `appcast.xml`.
   The script does not publish.
3. Smoke-test the notarized DMG: mount it, drag the app out, launch, and check
   **nvModern > Check for Updates…** is present.
4. Publish as a draft first, then promote it once happy:

   ```sh
   gh release create v2.1.0 dist/release/upload/nvModern-2.1.0.dmg \
     dist/release/upload/nvModern.dmg dist/release/upload/appcast.xml \
     --title "nvModern 2.1.0" --generate-notes --draft
   ```

   `releases/latest` ignores drafts and pre-releases, so installed apps only see
   the update after you publish.

Both assets must be attached to the same release. `appcast.xml` points at
`releases/download/v<version>/nvModern-<version>.dmg`, so the tag must be
`v<version>`.

## Versioning

- `MARKETING_VERSION` (shown to users) comes from `VERSION`.
- `CFBundleVersion` is a `yymmddHHMM` timestamp set at release time. Sparkle
  compares it, so it must always increase; it does not depend on git history.
- Source builds keep `CURRENT_PROJECT_VERSION: 0`.

## Signing notes

- The script builds unsigned, embeds the `nv3` CLI, then signs inside-out:
  Sparkle's helpers and framework, `nv3`, then the app, all with the hardened
  runtime. Signing before embedding `nv3` would invalidate the signature.
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
