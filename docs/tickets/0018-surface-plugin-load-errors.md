---
id: 0018
title: Surface Plugin Load Errors in the UI
status: done
type: improvement
area: plugins
priority: P2
created: 2026-10-08
updated: 2026-10-08
related:
  - ../architecture/plugins.md
  - ./0017-plugin-only-reload-path.md
---

# Surface Plugin Load Errors in the UI

## Completion status — 2026-10-08

Implementation and automated validation are complete. New or changed load errors
request "Plugin failed to load" notifications through `PluginAppEnvironment`;
unchanged errors are suppressed, and clearing an error rearms it. Global-hotkey
failures keep their beep and request a notification with the action title and
error at most once per method every ten seconds. Notification delivery failures
are logged without interrupting reloads or actions. Authoring and architecture
documentation describe the behavior.

`make` and `make test` passed (377 tests, two skipped, zero failures). New tests
cover duplicate errors, changed errors, recovery and recurrence, independent
method cooldowns, and the exact ten-second boundary. In the normal app, macOS
accepted a load-error notification containing the fixture filename and line 1;
a subsequent reload with the same error requested no repeat notification.
Evidence: `plugin/failureNotification.sent` in local diagnostics and
`/tmp/nvmodern/plugin-batch-smoke.log`.

Further validation after the user made the Mac available: the unchanged load
error requested no duplicate notification during plugin or Settings reloads.
Fixing the file cleared its load error silently; recreating the same error
requested a new notification, accepted by macOS after approximately 341 ms.
Evidence: `/tmp/nvmodern/plugin-batch-final-smoke.log`,
`/tmp/nvmodern/plugin-batch-load-error-final.json`, and local diagnostics.
All disposable plugins were removed, and original config bytes were restored.

Physical global-hotkey validation: the user pressed the disposable failing
action's shortcut repeatedly. Diagnostics recorded 23 failed invocations and
three accepted notification requests at 13:53:28, 13:53:39, and 13:54:01 UTC.
Rapid repeats were suppressed by the ten-second cooldown. Each request carried
the action title "0018 Validation Failure" and
"Error: 0018 disposable runtime error (line 4)".
Evidence: `/tmp/nvmodern/0018-global-hotkey-verification.json` and local diagnostics.
The disposable runtime fixture was removed; the live plugin list, load errors,
and global-hotkey list are empty again.

The user saw no banner. System Settings confirmed nvModern notifications and
temporary desktop banners are enabled, but Work Focus is on and nvModern is
outside its allowed-app list. Work Focus silences notifications from those
apps. The app's foreground notification delegate requests banner presentation;
macOS still controls presentation under Focus. Focus has not been changed.

Closed at the user's request. The physical callback, notification contents,
system acceptance, and runtime cooldown are verified; visible presentation is
not yet confirmed on this Mac because Work Focus suppresses nvModern banners.
The user will test visual presentation on their MacBook Pro and reopen this
ticket if that confirmation fails. No Focus settings were changed.

## Goal

A plugin with a syntax error or a thrown load-time exception is silently
absent; the error is only on stdout and in `nv3 action app.plugins.list`.
Authors save a file and nothing happens.

## Context

- `PluginHost.reload(sources:)` collects `loadErrors` as
  `"<file>.js: <message> (line N)"`.
- `PluginAppEnvironment.notify(title:message:)` posts a
  `UNUserNotificationCenter` banner (requests `.alert` authorization).
- `AppDelegate.reloadPlugins` prints the errors.

## Steps

1. After `PluginHost.shared.reload(...)` in `AppDelegate.reloadPlugins`, if
   `loadErrors` is non-empty and differs from the errors of the previous
   reload (keep the last set in a private var), post one notification per
   failing file: title "Plugin failed to load", body the error string. Use
   `pluginEnvironment.notify` so authorization handling is shared. Fire and
   forget inside a `Task`.
2. When a reload clears all errors, post nothing (silence is the success
   signal) but reset the remembered set.
3. Also surface runtime failures of hotkey-triggered actions: the global
   hotkey callback in `AppDelegate` beeps on `!response.ok`; add a notification
   with the action's title and the error message, rate-limited to once per
   method per 10 seconds.
4. Document both behaviours in `docs/plugins/authoring.md` (Debugging) and
   `docs/architecture/plugins.md` (Diagnostics).

## Acceptance

- Save a plugin file containing `this is not javascript`: a banner names the
  file and line within a second. Fix the file: no further banners.
- A capture whose `run` throws shows a banner with the message, and repeated
  presses do not flood notifications.

## Non-goals

- A persistent error list in Settings (see the Settings pane ticket).
