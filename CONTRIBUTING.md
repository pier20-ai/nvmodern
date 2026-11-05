# Contributing to nvModern

Thanks for your interest. nvModern is a native macOS notes workspace
(AppKit/SwiftUI shell, CodeMirror editor in a WKWebView, JavaScript plugins).

## Licence

nvModern is licensed under **GPL-3.0-or-later** (see [LICENSE](LICENSE) and
[NOTICE](NOTICE)). By submitting a contribution you agree that it is licensed
under the same terms, and that you have the right to submit it. Please do not
include code or assets you cannot license under the GPL.

## Toolchain

macOS 14 or later on Apple Silicon, Xcode with command-line tools, XcodeGen
and Bun. Optionally Racket, for the Arbor kernel tests.

```sh
make setup   # checks the toolchain, installs XcodeGen and Bun via Homebrew
make run     # build the web bundle and app, then launch it
```

## Always use `make`

Use `make` targets rather than calling `xcodebuild` or `bun` directly. The
Makefile keeps the web bundle, the generated Xcode project and the logs in sync.

| Target | Purpose |
|---|---|
| `make` | Web bundle, XcodeGen, Debug build |
| `make run` | Build and launch |
| `make test` | Swift unit tests |
| `make test-web` | WebEditor tests (`TEST_ARGS='...'` to filter) |
| `make typecheck-arbor` | Arbor TypeScript check |
| `make test-arbor-kernel` | Racket kernel tests (needs Racket) |
| `make dev` | Editor dev shell with hot reload at http://localhost:3000 |
| `make package` | Unsigned Release `.app` and `.dmg` in `dist/` |
| `make release` | Maintainers: signed, notarized DMG and Sparkle appcast (see [docs/releasing.md](docs/releasing.md)) |

Build and test logs are written to `/tmp/nvmodern/`.

## Ground rules

[AGENTS.md](AGENTS.md) lists the hard constraints (despite the name, they apply
to everyone). The ones that trip people up:

- Source folder, scheme and target are `NVModern`; the user-facing name is
  `nvModern`. Keep `project.yml` and the `Makefile` in sync.
- Native tabs are AppKit window tabs. Do not replace them with a custom strip.
- `NVModern/WebEditor/src/lib/` is framework-agnostic and must not import app
  code.
- The web bundle must be an IIFE; WKWebView will not load ES modules from
  `file://`.
- Do not commit `node_modules`, generated `NVModern/Resources/WebEditor/`
  files, or the generated Xcode project's user data.
- New commands are action descriptors in the action registry, not a separate
  command list. Personal workflows belong in
  [plugins](docs/plugins/authoring.md), not in core.

## Making a change

1. Open an issue first for anything larger than a bug fix, so we can agree on
   the approach.
2. Keep the change small and focused.
3. Add or update tests: Swift tests in `NVModernTests/`, web tests next to the
   code as `*.test.ts`. Tests must not depend on your own notes or plugins.
   Test fixtures live in `NVModern/WebEditor/test-files/`; keep them
   synthetic and free of private or third-party copyrighted content.
4. Run `make`, `make test` and, for editor or plugin changes, `make test-web`.
5. For shell or tab changes, walk through the smoke checklist in
   [AGENTS.md](AGENTS.md).
6. Update the relevant document under `docs/` when behaviour changes.

## Commits and pull requests

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org)
(`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`). In the PR
description say what changed and why, and how you tested it. For a change
people will notice, add a line under **Unreleased** in
[CHANGELOG.md](CHANGELOG.md).

## Architecture orientation

- [README](README.md): what it is and how to run it
- [docs/architecture/](docs/architecture/): palette, action system, plugins,
  configuration, search
- [docs/plugins/authoring.md](docs/plugins/authoring.md): writing plugins
- [NVModern/WebEditor/THEMING.md](NVModern/WebEditor/THEMING.md): editor themes

## Reporting security issues

Please do not open a public issue. See [SECURITY.md](SECURITY.md).

## Conduct

Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
