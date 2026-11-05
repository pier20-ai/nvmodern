export interface ArborMarkdownDocument {
  source: string;
  blocks: ArborMarkdownBlock[];
}

export type ArborMarkdownBlock =
  | { kind: "paragraph"; from: number; to: number; children: ArborMarkdownInline[] }
  | {
      kind: "heading";
      from: number;
      to: number;
      level: 1 | 2 | 3 | 4 | 5 | 6;
      children: ArborMarkdownInline[];
    }
  | {
      kind: "code-block";
      from: number;
      to: number;
      codeFrom: number;
      codeTo: number;
      language: string | null;
    }
  | { kind: "text-block"; from: number; to: number };

export type ArborMarkdownInline =
  | { kind: "text"; from: number; to: number }
  | {
      kind: "strong" | "emphasis" | "strikethrough" | "highlight";
      from: number;
      to: number;
      children: ArborMarkdownInline[];
    }
  | { kind: "code"; from: number; to: number; contentFrom: number; contentTo: number }
  | { kind: "page-link"; from: number; to: number; target: string }
  | { kind: "block-ref"; from: number; to: number; target: string }
  | { kind: "tag"; from: number; to: number; tag: string }
  | {
      kind: "link";
      from: number;
      to: number;
      href: string;
      children: ArborMarkdownInline[];
    }
  | { kind: "image"; from: number; to: number; src: string; alt: string }
  | {
      kind: "math";
      from: number;
      to: number;
      contentFrom: number;
      contentTo: number;
      display: boolean;
    };
