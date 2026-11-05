import React from "react";
import type { Nv3TocHeading } from "../plugins/headings.ts";

export interface Nv3TableOfContentsProps {
  headings: readonly Nv3TocHeading[];
  activeHeadingId?: string | null;
  onSelectHeading?: (heading: Nv3TocHeading) => void;
  className?: string;
}

const COLLAPSED_VISIBLE_COUNT = 8;

function collapsedHeadingWindow(
  headings: readonly Nv3TocHeading[],
  activeHeadingId?: string | null,
): {
  items: readonly Nv3TocHeading[];
  hiddenBefore: boolean;
  hiddenAfter: boolean;
} {
  if (headings.length <= COLLAPSED_VISIBLE_COUNT) {
    return {
      items: headings,
      hiddenBefore: false,
      hiddenAfter: false,
    };
  }

  const activeIndex = Math.max(
    0,
    activeHeadingId ? headings.findIndex((heading) => heading.id === activeHeadingId) : 0,
  );
  const halfWindow = Math.floor(COLLAPSED_VISIBLE_COUNT / 2);
  const maxStart = headings.length - COLLAPSED_VISIBLE_COUNT;
  const start = Math.min(Math.max(0, activeIndex - halfWindow), maxStart);
  const end = start + COLLAPSED_VISIBLE_COUNT;

  return {
    items: headings.slice(start, end),
    hiddenBefore: start > 0,
    hiddenAfter: end < headings.length,
  };
}

export function Nv3TableOfContents({
  headings,
  activeHeadingId,
  onSelectHeading,
  className,
}: Nv3TableOfContentsProps) {
  if (!headings.length) return null;

  const classes = ["nv3-toc", className].filter(Boolean).join(" ");
  const collapsed = collapsedHeadingWindow(headings, activeHeadingId);

  return (
    <nav className={classes} aria-label="Table of contents" tabIndex={0}>
      <div className="nv3-toc-collapsed" aria-hidden="true">
        {collapsed.hiddenBefore ? (
          <div className="nv3-toc-collapsed-more">
            <span />
            <span />
            <span />
          </div>
        ) : null}

        <ol className="nv3-toc-list nv3-toc-list-collapsed">
          {collapsed.items.map((heading) => {
            const isActive = heading.id === activeHeadingId;

            return (
              <li
                key={`collapsed-${heading.id}`}
                className={`nv3-toc-item nv3-toc-item-h${heading.level}${isActive ? " is-active" : ""}`}
              >
                <div className="nv3-toc-collapsed-entry">
                  <span className="nv3-toc-line" aria-hidden="true" />
                </div>
              </li>
            );
          })}
        </ol>

        {collapsed.hiddenAfter ? (
          <div className="nv3-toc-collapsed-more">
            <span />
            <span />
            <span />
          </div>
        ) : null}
      </div>

      <ol className="nv3-toc-list nv3-toc-list-expanded">
        {headings.map((heading) => {
          const isActive = heading.id === activeHeadingId;

          return (
            <li
              key={heading.id}
              className={`nv3-toc-item nv3-toc-item-h${heading.level}${isActive ? " is-active" : ""}`}
            >
              <button
                type="button"
                className="nv3-toc-button"
                onClick={() => onSelectHeading?.(heading)}
                title={heading.text}
              >
                <span className="nv3-toc-line" aria-hidden="true" />
                <span className="nv3-toc-label">{heading.text}</span>
              </button>
            </li>
          );
        })}
      </ol>
    </nav>
  );
}
