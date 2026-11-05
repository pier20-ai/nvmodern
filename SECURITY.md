# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately, not in a public issue or pull request.

Use GitHub's private vulnerability reporting: open the repository's **Security**
tab and choose **Report a vulnerability**. Include the affected version or
commit, what you observed, and the steps to reproduce it. We aim to acknowledge
a report within a few days and will keep you informed while we work on a fix.

## Supported versions

nvModern is under active development. Security fixes land on `master` and in
the latest release only.

## Trust model

nvModern is a local, single-user app. These design points define what counts as
a vulnerability:

- **Action socket.** The app listens on a Unix domain socket
  (`~/Library/Application Support/nvModern/action.sock` by default, mode 0600,
  disable with `[socket] enabled = false`). Anything that can connect as the
  same user can invoke actions, including reading and editing notes. This is
  how the `nv3` CLI and `nv3 mcp` work. A different local user, or a remote
  party, being able to use the socket would be a vulnerability. The same user
  using it is by design. Socket callers cannot claim the internal or menu
  source.
- **Plugins.** Plugins are plain JavaScript files in
  `~/.config/nvmodern/plugins/`, run in-process in JavaScriptCore. They are
  trusted code that you install yourself. They have no network or shell access,
  but they can read and write files, including outside your notes folders, and
  invoke actions. There is no permission prompt and no sandbox. A plugin
  escaping the capabilities the host installs would be a vulnerability. A
  malicious plugin you chose to install is not.
- **Documents.** Notes, Org/Markdown files, HTML previews, EPUBs, PDFs and
  Excalidraw canvases may come from untrusted sources. Script execution,
  arbitrary file reads or writes, or access to the action socket from document
  content are vulnerabilities.
- **Web content.** The editor runs in a WKWebView loading bundled local
  resources and the `nvmodern-file://` scheme. Any way for document content to
  reach files outside the intended scope through these paths is in scope.
- **MCP.** `nv3 mcp` exposes a curated allowlist of actions to the MCP client
  you connect. Treat connected MCP clients as having your access to the notes
  the allowlist covers.

Out of scope: denial of service by a local user who already has your account,
and issues that require an attacker to edit your config or plugins first.
