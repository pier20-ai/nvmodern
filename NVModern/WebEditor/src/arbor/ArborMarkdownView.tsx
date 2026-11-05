import katex from "katex";
import React, { useMemo, type ReactNode } from "react";
import {
  parseArborMarkdown,
  parseArborMarkdownTask,
  type ArborMarkdownBlock,
  type ArborMarkdownInline,
} from "../lib/arbor/markdown/index.ts";
import { Checkbox } from "../components/ui/checkbox.tsx";

interface ArborMarkdownViewProps {
  source: string;
  onNavigate(navigation: ArborMarkdownNavigation): void;
  onTaskToggle?(checked: boolean): void;
}

export type ArborMarkdownNavigation =
  | { kind: "external"; href: string }
  | { kind: "page"; target: string }
  | { kind: "block"; target: string };

function sourcePosition(from: number, to: number, offset = 0) {
  return {
    "data-source-start": from + offset,
    "data-source-end": to + offset,
  };
}

function renderInlines(
  nodes: ArborMarkdownInline[],
  source: string,
  onNavigate: ArborMarkdownViewProps["onNavigate"],
  sourceOffset: number,
): ReactNode[] {
  return nodes.map((node, index) => {
    const key = `${node.from}-${node.to}-${index}`;

    switch (node.kind) {
      case "text":
        return <span {...sourcePosition(node.from, node.to, sourceOffset)} key={key}>{source.slice(node.from, node.to)}</span>;
      case "strong":
        return <strong className="arbor-strong" key={key}>{renderInlines(node.children, source, onNavigate, sourceOffset)}</strong>;
      case "emphasis":
        return <em className="arbor-emphasis" key={key}>{renderInlines(node.children, source, onNavigate, sourceOffset)}</em>;
      case "strikethrough":
        return <s className="arbor-strikethrough" key={key}>{renderInlines(node.children, source, onNavigate, sourceOffset)}</s>;
      case "highlight":
        return <mark className="arbor-highlight" key={key}>{renderInlines(node.children, source, onNavigate, sourceOffset)}</mark>;
      case "code":
        return (
          <code
            className="arbor-inline-code"
            {...sourcePosition(node.contentFrom, node.contentTo, sourceOffset)}
            key={key}
          >
            {source.slice(node.contentFrom, node.contentTo)}
          </code>
        );
      case "page-link":
        return (
          <button
            type="button"
            className="arbor-rendered-link arbor-page-link"
            {...sourcePosition(node.from + 2, node.to - 2, sourceOffset)}
            onMouseDown={(event) => event.stopPropagation()}
            onClick={() => onNavigate({ kind: "page", target: node.target })}
            key={key}
          >
            {node.target}
          </button>
        );
      case "block-ref":
        return (
          <button
            type="button"
            className="arbor-rendered-link arbor-block-ref"
            {...sourcePosition(node.from, node.to, sourceOffset)}
            onMouseDown={(event) => event.stopPropagation()}
            onClick={() => onNavigate({ kind: "block", target: node.target })}
            key={key}
          >
            {source.slice(node.from, node.to)}
          </button>
        );
      case "tag":
        return (
          <span className="arbor-tag" {...sourcePosition(node.from, node.to, sourceOffset)} key={key}>
            #{node.tag}
          </span>
        );
      case "link":
        return (
          <a
            className="arbor-rendered-link arbor-link"
            href={node.href}
            title={node.href}
            {...sourcePosition(node.from, node.to, sourceOffset)}
            onMouseDown={(event) => event.stopPropagation()}
            onClick={(event) => {
              event.preventDefault();
              onNavigate({ kind: "external", href: node.href });
            }}
            key={key}
          >
            {renderInlines(node.children, source, onNavigate, sourceOffset)}
          </a>
        );
      case "image":
        return (
          <span
            className="arbor-image"
            {...sourcePosition(node.from, node.to, sourceOffset)}
            key={key}
          >
            <img src={node.src} alt={node.alt} loading="lazy" />
          </span>
        );
      case "math": {
        const expression = source.slice(node.contentFrom, node.contentTo);
        let html: string | null = null;
        try {
          html = katex.renderToString(expression, {
            displayMode: node.display,
            output: "html",
            strict: "ignore",
            throwOnError: false,
          });
        } catch {}
        return (
          <span
            className={node.display ? "arbor-math is-display" : "arbor-math"}
            {...sourcePosition(node.contentFrom, node.contentTo, sourceOffset)}
            key={key}
            {...(html ? { dangerouslySetInnerHTML: { __html: html } } : {})}
          >
            {html ? null : expression}
          </span>
        );
      }
    }
  });
}

function renderBlock(
  block: ArborMarkdownBlock,
  source: string,
  onNavigate: ArborMarkdownViewProps["onNavigate"],
  key: string,
  sourceOffset: number,
): ReactNode {
  switch (block.kind) {
    case "paragraph":
      return <span className="arbor-paragraph" key={key}>{renderInlines(block.children, source, onNavigate, sourceOffset)}</span>;
    case "heading":
      return (
        <span className="arbor-heading" data-heading-level={block.level} key={key}>
          {renderInlines(block.children, source, onNavigate, sourceOffset)}
        </span>
      );
    case "code-block":
      return (
        <code
          className="arbor-code-block"
          data-language={block.language ?? undefined}
          {...sourcePosition(block.codeFrom, block.codeTo, sourceOffset)}
          key={key}
        >
          {source.slice(block.codeFrom, block.codeTo)}
        </code>
      );
    case "text-block":
      return (
        <span {...sourcePosition(block.from, block.to, sourceOffset)} key={key}>
          {source.slice(block.from, block.to)}
        </span>
      );
  }
}

function ArborMarkdownContent({
  source,
  sourceOffset,
  onNavigate,
}: {
  source: string;
  sourceOffset: number;
  onNavigate: ArborMarkdownViewProps["onNavigate"];
}) {
  const document = useMemo(() => parseArborMarkdown(source), [source]);
  const content: ReactNode[] = [];
  let cursor = 0;
  document.blocks.forEach((block, index) => {
    if (cursor < block.from) {
      content.push(
        <span {...sourcePosition(cursor, block.from, sourceOffset)} key={`gap-${cursor}`}>
          {source.slice(cursor, block.from)}
        </span>,
      );
    }
    content.push(renderBlock(block, source, onNavigate, `block-${block.from}-${index}`, sourceOffset));
    cursor = block.to;
  });
  if (cursor < source.length) {
    content.push(
      <span {...sourcePosition(cursor, source.length, sourceOffset)} key={`tail-${cursor}`}>
        {source.slice(cursor)}
      </span>,
    );
  }
  return <>{content}</>;
}

export function ArborMarkdownView({ source, onNavigate, onTaskToggle }: ArborMarkdownViewProps) {
  const task = useMemo(() => parseArborMarkdownTask(source), [source]);
  if (!source) return <span className="arbor-placeholder">Write something…</span>;
  if (!task) return <ArborMarkdownContent source={source} sourceOffset={0} onNavigate={onNavigate} />;

  return (
    <span className="arbor-task" data-checked={task.checked ? "true" : "false"}>
      <Checkbox
        checked={task.checked}
        disabled={!onTaskToggle}
        aria-label={task.checked ? "Mark task incomplete" : "Mark task complete"}
        onMouseDown={(event) => event.stopPropagation()}
        onClick={(event) => event.stopPropagation()}
        onCheckedChange={(checked) => onTaskToggle?.(checked)}
      />
      <span className="arbor-task-content">
        <ArborMarkdownContent
          source={source.slice(task.contentOffset)}
          sourceOffset={task.contentOffset}
          onNavigate={onNavigate}
        />
      </span>
    </span>
  );
}
