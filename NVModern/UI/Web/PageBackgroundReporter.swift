import AppKit

/// Reports the editor page's background colour to the host, so window chrome
/// can take the colour of the document it shows (scratchpads, and workspace
/// windows when the window tint is on).
enum PageBackgroundReporter {
    /// User script that posts `event` with `{ rgb: [r, g, b] }` whenever the
    /// page's resolved `--nv3-color-bg` changes: theme stylesheets, document
    /// appearance and light/dark switches all land in <head> or on <html>.
    static func script(event: String) -> String {
        """
        (function () {
          var pending = false, previous = "";
          function update() {
            pending = false;
            var shell = document.querySelector('.nvmodern-editor-shell') || document.body;
            if (!shell) return;
            var probe = document.createElement('span');
            probe.style.cssText = 'position:absolute;visibility:hidden;pointer-events:none;background:var(--bg,var(--nv3-color-bg,#fff))';
            shell.appendChild(probe);
            var color = getComputedStyle(probe).backgroundColor;
            probe.remove();
            if (color === previous) return;
            previous = color;
            // A 1px canvas resolves color-mix(), oklch() and friends to sRGB.
            var canvas = document.createElement('canvas');
            canvas.width = canvas.height = 1;
            var ctx = canvas.getContext('2d');
            ctx.fillStyle = color;
            ctx.fillRect(0, 0, 1, 1);
            var pixel = ctx.getImageData(0, 0, 1, 1).data;
            window.webkit.messageHandlers.nvmodern.postMessage({
              kind: 'event', event: '\(event)', payload: { rgb: [pixel[0], pixel[1], pixel[2]] }
            });
          }
          function schedule() {
            if (!pending) { pending = true; requestAnimationFrame(update); }
          }
          var observer = new MutationObserver(schedule);
          observer.observe(document.documentElement, { attributes: true });
          observer.observe(document.body, { attributes: true });
          observer.observe(document.head, { childList: true, subtree: true, characterData: true, attributes: true });
          schedule();
        })();
        """
    }

    /// The colour carried by a reporter event payload.
    static func color(from payload: [String: Any]) -> NSColor? {
        guard let rgb = payload["rgb"] as? [Double], rgb.count == 3,
              rgb.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 255 }) else {
            return nil
        }
        return NSColor(srgbRed: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255, alpha: 1)
    }
}
