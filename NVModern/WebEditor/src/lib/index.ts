import type { HelpOpenRequest } from "./help/model.ts";
export type { HelpOpenRequest, HelpProvider, HelpTopic } from "./help/model.ts";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import {
  bracketMatching,
  defaultHighlightStyle,
  foldKeymap,
  HighlightStyle,
  indentOnInput,
  indentUnit,
  syntaxHighlighting,
} from "@codemirror/language";
import { yamlFrontmatter } from "@codemirror/lang-yaml";
import { highlightSelectionMatches, search, searchKeymap } from "@codemirror/search";
import { Compartment, EditorState, type EditorStateConfig, type Extension } from "@codemirror/state";
import {
  drawSelection,
  dropCursor,
  EditorView,
  highlightSpecialChars,
  keymap,
} from "@codemirror/view";
import { tags } from "@lezer/highlight";
import { codeLanguageForInfo } from "./codeLanguages.ts";
import { detectNv3FileType, type Nv3FileType } from "./filetype.ts";
import { createNv3InteractionStateExtension } from "./plugins/interactionState.ts";
import {
  createMarkdownCodeFenceExtension,
  type Nv3CodeBlockIndex,
} from "./plugins/codeFences.ts";
import { createMarkdownCalloutExtension } from "./plugins/callouts.ts";
import { createMarkdownBlockReferenceExtension } from "./plugins/blockReferences.ts";
import { createNv3EditorBottomSpaceExtension } from "./plugins/bottomSpace.ts";
import { createNv3AnnotationsExtension } from "./plugins/annotations.ts";
import {
  createNv3AutocompleteExtension,
  type Nv3AutocompleteError,
  type Nv3AutocompleteProvider,
} from "./plugins/autocomplete.ts";
import {
  createMarkdownFrontmatterExtension,
  defaultNv3FrontmatterSchema,
  type Nv3FrontmatterResult,
  type Nv3FrontmatterSchema,
} from "./plugins/frontmatter.ts";
import {
  createMarkdownLatexExtension,
  type Nv3LatexIndex,
  type Nv3LatexPreviewMode,
} from "./plugins/latex.ts";
import {
  createMarkdownLinkExtension,
  type Nv3InlineLinkHrefInput,
  type Nv3InlineLinkOpenInput,
  type Nv3LinkIndex,
  type Nv3WikilinkHrefInput,
  type Nv3WikilinkOpenInput,
} from "./plugins/links.ts";
import {
  createMarkdownDatesExtension,
  type Nv3DatePickerSelection,
  type Nv3MarkdownDatePickerRequest,
} from "./plugins/dates.ts";
import { createMarkdownFootnoteExtension } from "./plugins/footnotes.ts";
import {
  createInlineFormattingKeymap,
  createMarkdownInlineFormattingExtension,
} from "./plugins/inlineFormatting.ts";
import { createNv3SubstitutionsExtension, type Nv3TextSubstitutionRule } from "./plugins/substitutions.ts";
import { createMarkdownListEditingExtension } from "./plugins/listEditing.ts";
import { createMarkdownListPrefixesExtension } from "./plugins/listPrefixes.ts";
import { createMarkdownHeadingFoldingExtension } from "./plugins/headingFolding.ts";
import { createMarkdownHeadingPrefixesExtension } from "./plugins/headingPrefixes.ts";
import {
  documentScanField,
  documentScannerFacet,
} from "./plugins/documentIndex.ts";
import { markdownDocumentScanner } from "./plugins/markdownScanner.ts";
import { createMarkdownTablesExtension } from "./plugins/tables.ts";
import { createMarkdownFrontmatterPropertiesExtension } from "./plugins/frontmatterProperties.ts";
import { createMarkdownMarksHidingExtension } from "./plugins/marksHiding.ts";
import { createMarkdownHighlightExtension } from "./plugins/highlights.ts";
import { createMarkdownHorizontalRuleExtension } from "./plugins/horizontalRules.ts";
import { createMarkdownMentionExtension } from "./plugins/mentions.ts";
import { createMarkdownTagExtension, type Nv3TagIndex } from "./plugins/markdownTags.ts";
import { createMarkdownInlineCodeStylingExtension } from "./plugins/inlineCodeStyling.ts";
import { createMarkdownTodoHeadingsExtension } from "./plugins/todoHeadings.ts";
import {
  createMarkdownTransclusionExtension,
  type MarkdownTransclusionOptions,
  type Nv3TransclusionNestedStateInput,
  type Nv3TransclusionResolveInput,
  type Nv3TransclusionResolved,
  type Nv3TransclusionSaveInput,
} from "./plugins/transclusion.ts";
import { createNv3OrgParserExtension, orgDocumentScanner } from "./plugins/orgIndex.ts";
import { createOrgModeExtension } from "./org/orgExtension.ts";
import { createOrgSourceHighlightExtension } from "./org/orgSourceHighlight.ts";
import { createOrgTablesExtension } from "./plugins/orgTables.ts";
import { createAutoLinksExtension } from "./plugins/autoLinks.ts";
import { createOrgListEditingExtension } from "./plugins/orgListEditing.ts";
import { createMarkdownImagePreviewExtension } from "./plugins/imagePreview.ts";
import { createMarkdownMermaidExtension } from "./plugins/mermaid.ts";
import { createMarkdownCalcExtension } from "./plugins/calc.ts";
import { createNv3SelectionLayerRepaintExtension } from "./plugins/selectionLayerRepaint.ts";
import { type Nv3OrgParseResult } from "./org/parser.ts";
import { nv3NotionEditorTheme } from "./theme/notionTheme.ts";

export const NV3_PLUGIN_SLOTS = [
  "folding",
  "cosmetics",
  "tags",
  "frontmatter",
  "latex",
  "codeBlocks",
  "links",
  "transclusion",
  "media",
  "tables",
  "codeExecution",
] as const;

export type Nv3PluginSlot = (typeof NV3_PLUGIN_SLOTS)[number];
export type Nv3PluginSlotExtensions = Partial<Record<Nv3PluginSlot, Extension[]>>;

export interface Nv3EditorRuntime {
  language: Compartment;
  slots: Record<Nv3PluginSlot, Compartment>;
}

export interface Nv3EditorExtensionsOptions {
  onHelpOpen?: (request: HelpOpenRequest) => void;
  filePath?: string;
  fileType?: Nv3FileType;
  onDocChange?: (doc: string) => void;
  onTagsChange?: (index: Nv3TagIndex) => void;
  onFrontmatterChange?: (result: Nv3FrontmatterResult) => void;
  onLatexChange?: (index: Nv3LatexIndex) => void;
  latexPreviewMode?: Nv3LatexPreviewMode;
  onCodeBlocksChange?: (index: Nv3CodeBlockIndex) => void;
  onLinksChange?: (index: Nv3LinkIndex) => void;
  onOrgParseChange?: (result: Nv3OrgParseResult) => void;
  onOrgTodoMenuOpen?: (input: {
    from: number;
    to: number;
    current: string;
    states: readonly string[];
    event: MouseEvent;
    view: EditorView;
  }) => void;
  onWikilinkOpen?: (input: Nv3WikilinkOpenInput) => void;
  onInlineLinkOpen?: (input: Nv3InlineLinkOpenInput) => void;
  resolveWikilinkHref?: (input: Nv3WikilinkHrefInput) => string;
  resolveInlineLinkHref?: (input: Nv3InlineLinkHrefInput) => string;
  resolveTransclusion?: (
    input: Nv3TransclusionResolveInput,
  ) => Promise<Nv3TransclusionResolved | null>;
  saveTransclusion?: (input: Nv3TransclusionSaveInput) => Promise<void>;
  maxTransclusionDepth?: number;
  createNestedTransclusionState?: (input: Nv3TransclusionNestedStateInput) => EditorState;
  frontmatterSchema?: Nv3FrontmatterSchema;
  autocompleteProviders?: readonly Nv3AutocompleteProvider[];
  autocompleteActivateOnTypingDelay?: number;
  onAutocompleteError?: (error: Nv3AutocompleteError) => void;
  pickDate?: (request: Nv3MarkdownDatePickerRequest) => Promise<Nv3DatePickerSelection | null>;
  substitutionRules?: readonly Nv3TextSubstitutionRule[];
  resolveImageUrl?: (src: string) => string | null;
  onImagePaste?: (data: string, mimeType: string) => Promise<string | null>;
  pluginSlots?: Nv3PluginSlotExtensions;
  extraExtensions?: Extension[];
  runtime?: Nv3EditorRuntime;
  minimalPlugins?: boolean;
  /** @internal */
  _transclusionDepth?: number;
}

export interface CreateNv3EditorStateOptions extends Nv3EditorExtensionsOptions {
  doc?: string;
  selection?: EditorStateConfig["selection"];
}

export interface Nv3MarkdownExtensionsOptions extends Omit<Nv3EditorExtensionsOptions, "fileType"> {}

export interface CreateNv3MarkdownStateOptions extends Nv3MarkdownExtensionsOptions {
  doc?: string;
}

export const nv3MarkdownHighlightStyle = HighlightStyle.define([
  {
    tag: tags.heading1,
    fontFamily: "var(--nv3-md-h1-font-family)",
    fontSize: "var(--nv3-md-h1-font-size)",
    fontWeight: "var(--nv3-md-h1-font-weight)",
    lineHeight: "var(--nv3-md-h1-line-height)",
    letterSpacing: "var(--nv3-md-h1-letter-spacing)",
    fontStyle: "var(--nv3-md-h1-font-style)",
    fontFeatureSettings: "var(--nv3-md-h1-font-feature-settings)",
    textTransform: "var(--nv3-md-h1-text-transform)",
    color: "var(--nv3-md-h1-color)",
  },
  {
    tag: tags.heading2,
    fontFamily: "var(--nv3-md-h2-font-family)",
    fontSize: "var(--nv3-md-h2-font-size)",
    fontWeight: "var(--nv3-md-h2-font-weight)",
    lineHeight: "var(--nv3-md-h2-line-height)",
    letterSpacing: "var(--nv3-md-h2-letter-spacing)",
    fontStyle: "var(--nv3-md-h2-font-style)",
    fontFeatureSettings: "var(--nv3-md-h2-font-feature-settings)",
    textTransform: "var(--nv3-md-h2-text-transform)",
    color: "var(--nv3-md-h2-color)",
  },
  {
    tag: tags.heading3,
    fontFamily: "var(--nv3-md-h3-font-family)",
    fontSize: "var(--nv3-md-h3-font-size)",
    fontWeight: "var(--nv3-md-h3-font-weight)",
    lineHeight: "var(--nv3-md-h3-line-height)",
    letterSpacing: "var(--nv3-md-h3-letter-spacing)",
    fontStyle: "var(--nv3-md-h3-font-style)",
    fontFeatureSettings: "var(--nv3-md-h3-font-feature-settings)",
    textTransform: "var(--nv3-md-h3-text-transform)",
    color: "var(--nv3-md-h3-color)",
  },
  {
    tag: tags.heading4,
    fontFamily: "var(--nv3-md-h4-font-family)",
    fontSize: "var(--nv3-md-h4-font-size)",
    fontWeight: "var(--nv3-md-h4-font-weight)",
    lineHeight: "var(--nv3-md-h4-line-height)",
    letterSpacing: "var(--nv3-md-h4-letter-spacing)",
    fontStyle: "var(--nv3-md-h4-font-style)",
    fontFeatureSettings: "var(--nv3-md-h4-font-feature-settings)",
    textTransform: "var(--nv3-md-h4-text-transform)",
    color: "var(--nv3-md-h4-color)",
  },
  {
    tag: tags.heading5,
    fontFamily: "var(--nv3-md-h5-font-family)",
    fontSize: "var(--nv3-md-h5-font-size)",
    fontWeight: "var(--nv3-md-h5-font-weight)",
    lineHeight: "var(--nv3-md-h5-line-height)",
    letterSpacing: "var(--nv3-md-h5-letter-spacing)",
    fontStyle: "var(--nv3-md-h5-font-style)",
    fontFeatureSettings: "var(--nv3-md-h5-font-feature-settings)",
    textTransform: "var(--nv3-md-h5-text-transform)",
    color: "var(--nv3-md-h5-color)",
  },
  {
    tag: tags.heading6,
    fontFamily: "var(--nv3-md-h6-font-family)",
    fontSize: "var(--nv3-md-h6-font-size)",
    fontWeight: "var(--nv3-md-h6-font-weight)",
    lineHeight: "var(--nv3-md-h6-line-height)",
    letterSpacing: "var(--nv3-md-h6-letter-spacing)",
    fontStyle: "var(--nv3-md-h6-font-style)",
    fontFeatureSettings: "var(--nv3-md-h6-font-feature-settings)",
    textTransform: "var(--nv3-md-h6-text-transform)",
    color: "var(--nv3-md-h6-color)",
  },

  { tag: tags.strong, fontWeight: "600" },
  { tag: tags.emphasis, fontStyle: "italic" },
  { tag: tags.strikethrough, textDecoration: "line-through" },

  { tag: [tags.link, tags.url], color: "var(--text)", textDecoration: "underline" },
  { tag: tags.meta, color: "var(--text-tertiary)" },
  { tag: tags.processingInstruction, color: "var(--text)" },
  { tag: tags.quote, color: "var(--text-secondary)" },
  { tag: tags.list, color: "inherit" },

  // Code block / embedded language tokens (fenced blocks, plain/org, etc.)
  { tag: tags.invalid, color: "var(--cm-invalid)" },
  { tag: tags.inserted, color: "var(--cm-inserted)" },
  { tag: tags.deleted, color: "var(--cm-deleted)" },
  { tag: tags.changed, color: "var(--cm-type)" },

  {
    tag: [tags.comment, tags.lineComment, tags.blockComment],
    color: "var(--text-tertiary)",
    fontStyle: "italic",
  },
  { tag: tags.docComment, color: "var(--cm-doc-comment)", fontStyle: "italic" },

  {
    tag: [
      tags.keyword,
      tags.self,
      tags.unit,
      tags.modifier,
      tags.operatorKeyword,
      tags.controlKeyword,
      tags.definitionKeyword,
      tags.moduleKeyword,
      tags.atom,
    ],
    color: "var(--cm-keyword)",
  },

  {
    tag: [
      tags.operator,
      tags.derefOperator,
      tags.arithmeticOperator,
      tags.logicOperator,
      tags.bitwiseOperator,
      tags.compareOperator,
      tags.updateOperator,
      tags.definitionOperator,
      tags.typeOperator,
      tags.controlOperator,
    ],
    color: "var(--cm-operator)",
  },

  {
    tag: [
      tags.punctuation,
      tags.separator,
      tags.bracket,
      tags.angleBracket,
      tags.squareBracket,
      tags.paren,
      tags.brace,
    ],
    color: "var(--cm-punctuation)",
  },

  { tag: [tags.string, tags.special(tags.string)], color: "var(--cm-string)" },
  {
    tag: [tags.character, tags.docString, tags.attributeValue],
    color: "var(--cm-string)",
  },
  { tag: tags.regexp, color: "var(--cm-regexp)" },
  { tag: tags.escape, color: "var(--cm-escape)" },
  { tag: tags.color, color: "var(--cm-number)" },

  { tag: [tags.number, tags.integer, tags.float], color: "var(--cm-number)" },
  { tag: tags.bool, color: "var(--cm-atom)" },
  { tag: tags.null, color: "var(--cm-atom)" },

  {
    tag: [tags.className, tags.typeName, tags.tagName],
    color: "var(--cm-type)",
  },
  {
    tag: [tags.namespace, tags.labelName, tags.macroName],
    color: "var(--cm-namespace)",
  },
  {
    tag: [tags.propertyName, tags.attributeName],
    color: "var(--cm-property)",
  },
  { tag: tags.name, color: "var(--cm-variable)" },
  { tag: tags.variableName, color: "var(--cm-variable)" },
  {
    tag: tags.local(tags.variableName),
    color: "var(--cm-variable)",
  },
  {
    tag: tags.definition(tags.variableName),
    color: "var(--cm-definition)",
  },
  {
    tag: tags.constant(tags.variableName),
    color: "var(--cm-atom)",
  },
  {
    tag: tags.standard(tags.variableName),
    color: "var(--cm-namespace)",
  },
  {
    tag: tags.special(tags.variableName),
    color: "var(--cm-variable)",
    fontStyle: "italic",
  },
  {
    tag: tags.definition(tags.propertyName),
    color: "var(--cm-property)",
  },
  {
    tag: [tags.function(tags.variableName), tags.function(tags.propertyName)],
    color: "var(--cm-function)",
  },
]);

function createSlotCompartments(): Record<Nv3PluginSlot, Compartment> {
  return {
    folding: new Compartment(),
    cosmetics: new Compartment(),
    tags: new Compartment(),
    frontmatter: new Compartment(),
    latex: new Compartment(),
    codeBlocks: new Compartment(),
    links: new Compartment(),
    transclusion: new Compartment(),
    media: new Compartment(),
    tables: new Compartment(),
    codeExecution: new Compartment(),
  };
}

export function createNv3EditorRuntime(): Nv3EditorRuntime {
  return {
    language: new Compartment(),
    slots: createSlotCompartments(),
  };
}

function emptySlotExtensions(): Record<Nv3PluginSlot, Extension[]> {
  return {
    folding: [],
    cosmetics: [],
    tags: [],
    frontmatter: [],
    latex: [],
    codeBlocks: [],
    links: [],
    transclusion: [],
    media: [],
    tables: [],
    codeExecution: [],
  };
}

function languageExtensionFor(fileType: Nv3FileType): Extension {
  switch (fileType) {
    case "markdown": {
      const markdownSupport = markdown({
        codeLanguages: codeLanguageForInfo,
        addKeymap: false,
        extensions: [{ remove: ["IndentedCode", "SetextHeading", "Link", "Image"] }],
      });

      return [
        yamlFrontmatter({ content: markdownSupport }),
        indentUnit.of("    "),
        EditorView.editorAttributes.of({ "data-nv3-language": "markdown" }),
      ];
    }

    case "org":
      return EditorView.editorAttributes.of({ "data-nv3-language": "org" });

    case "plain":
    default:
      return EditorView.editorAttributes.of({ "data-nv3-language": "plain" });
  }
}

export function createNv3DefaultSlotExtensions(
  fileType: Nv3FileType,
  options: Nv3EditorExtensionsOptions,
): Record<Nv3PluginSlot, Extension[]> {
  const slots = emptySlotExtensions();

  if (options.minimalPlugins) {
    return slots;
  }

  // ── Plugins shared across languages (consume DocumentScanIndex) ─────

  if (fileType === "markdown" || fileType === "org") {
    slots.tags.push(
      createMarkdownTagExtension({
        onChange: options.onTagsChange,
      }),
    );
    slots.tags.push(createMarkdownBlockReferenceExtension());

    slots.latex.push(
      createMarkdownLatexExtension({
        onChange: options.onLatexChange,
        previewMode: options.latexPreviewMode ?? "none",
      }),
    );

    slots.codeBlocks.push(
      createMarkdownCodeFenceExtension({
        onChange: options.onCodeBlocksChange,
      }),
    );

    slots.links.push(createAutoLinksExtension());
  }

  if (fileType !== "markdown") {
    return slots;
  }

  // ── Markdown-only plugins ───────────────────────────────────────────

  slots.folding.push(createMarkdownHeadingFoldingExtension());

  slots.cosmetics.push(createMarkdownHeadingPrefixesExtension());
  slots.cosmetics.push(createMarkdownMarksHidingExtension());
  slots.cosmetics.push(createMarkdownHighlightExtension());
  slots.cosmetics.push(createMarkdownHorizontalRuleExtension());
  slots.cosmetics.push(createMarkdownInlineCodeStylingExtension());
  slots.cosmetics.push(createMarkdownCalloutExtension());
  slots.cosmetics.push(createMarkdownListPrefixesExtension());
  slots.cosmetics.push(createMarkdownTodoHeadingsExtension());

  slots.tags.push(createMarkdownMentionExtension());

  slots.frontmatter.push(
    createMarkdownFrontmatterExtension({
      schema: options.frontmatterSchema ?? defaultNv3FrontmatterSchema,
      onChange: options.onFrontmatterChange,
    }),
  );
  slots.frontmatter.push(
    createMarkdownFrontmatterPropertiesExtension({
      onWikilinkOpen: options.onWikilinkOpen,
      onInlineLinkOpen: options.onInlineLinkOpen,
    }),
  );

  slots.links.push(
    createMarkdownLinkExtension({
      filePath: options.filePath,
      onChange: options.onLinksChange,
      onWikilinkOpen: options.onWikilinkOpen,
      onInlineLinkOpen: options.onInlineLinkOpen,
      resolveWikilinkHref: options.resolveWikilinkHref,
      resolveInlineLinkHref: options.resolveInlineLinkHref,
    }),
  );
  slots.links.push(createMarkdownFootnoteExtension());

  const transclusionDepth = options._transclusionDepth ?? 0;
  const maxTransclusionDepth = options.maxTransclusionDepth ?? 1;

  if (options.resolveTransclusion && transclusionDepth < maxTransclusionDepth) {
    const createNestedState =
      options.createNestedTransclusionState ??
      ((input: Nv3TransclusionNestedStateInput) =>
        createNv3EditorState({
          doc: input.content,
          filePath: input.filePath ?? options.filePath,
          onDocChange: input.onDocChange,
          resolveWikilinkHref: options.resolveWikilinkHref,
          resolveInlineLinkHref: options.resolveInlineLinkHref,
          onWikilinkOpen: options.onWikilinkOpen,
          onInlineLinkOpen: options.onInlineLinkOpen,
          resolveTransclusion: options.resolveTransclusion,
          saveTransclusion: options.saveTransclusion,
          maxTransclusionDepth: options.maxTransclusionDepth,
          frontmatterSchema: options.frontmatterSchema,
          autocompleteProviders: options.autocompleteProviders,
          autocompleteActivateOnTypingDelay: options.autocompleteActivateOnTypingDelay,
          onAutocompleteError: options.onAutocompleteError,
          pickDate: options.pickDate,
          substitutionRules: options.substitutionRules,
          resolveImageUrl: options.resolveImageUrl,
          onImagePaste: options.onImagePaste,
          latexPreviewMode: options.latexPreviewMode,
          _transclusionDepth: input.depth,
        }));

    const transclusionOptions: MarkdownTransclusionOptions = {
      filePath: options.filePath,
      depth: transclusionDepth,
      maxDepth: maxTransclusionDepth,
      resolveTransclusion: options.resolveTransclusion,
      saveTransclusion: options.saveTransclusion,
      createNestedState,
    };

    slots.transclusion.push(createMarkdownTransclusionExtension(transclusionOptions));
  }

  slots.media.push(
    createMarkdownImagePreviewExtension({
      filePath: options.filePath,
      resolveImageUrl: options.resolveImageUrl,
      onImagePaste: options.onImagePaste,
    }),
  );

  slots.media.push(createMarkdownMermaidExtension());

  slots.tables.push(createMarkdownTablesExtension());

  slots.codeExecution.push(createMarkdownCalcExtension({ onHelpOpen: options.onHelpOpen }));

  return slots;
}

function baseExtensions(options: Nv3EditorExtensionsOptions = {}): Extension[] {
  const base: Extension[] = [
    nv3NotionEditorTheme,
    createNv3InteractionStateExtension(),
    createNv3SubstitutionsExtension({ rules: options.substitutionRules }),
    highlightSpecialChars(),
    history(),
    drawSelection(),
    createNv3SelectionLayerRepaintExtension(),
    dropCursor(),
    indentOnInput(),
    bracketMatching(),
    highlightSelectionMatches(),
    search(),
    syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
    syntaxHighlighting(nv3MarkdownHighlightStyle),
    EditorView.lineWrapping,
    EditorState.allowMultipleSelections.of(true),
    keymap.of([
      indentWithTab,
      ...defaultKeymap,
      ...historyKeymap,
      ...searchKeymap.filter((binding) => binding.key !== "Mod-f"),
      ...foldKeymap,
    ]),
  ];

  if (options.onDocChange) {
    base.push(
      EditorView.updateListener.of((update) => {
        if (!update.docChanged) return;
        options.onDocChange?.(update.state.doc.toString());
      }),
    );
  }

  return base;
}

function resolveFileType(options: Nv3EditorExtensionsOptions): Nv3FileType {
  if (options.fileType) return options.fileType;
  if (options.filePath) return detectNv3FileType(options.filePath);
  return "markdown";
}

export function createNv3EditorExtensions(options: Nv3EditorExtensionsOptions = {}): Extension[] {
  const runtime = options.runtime ?? createNv3EditorRuntime();
  const fileType = resolveFileType(options);

  const extensions: Extension[] = [
    ...baseExtensions(options),
    runtime.language.of(languageExtensionFor(fileType)),
  ];

  if ((fileType === "markdown" || fileType === "org") && (options._transclusionDepth ?? 0) === 0) {
    extensions.push(createNv3EditorBottomSpaceExtension());
  }

  if ((options._transclusionDepth ?? 0) === 0) {
    extensions.push(createNv3AnnotationsExtension());
  }

  if (fileType === "markdown" || fileType === "org") {
    extensions.push(
      createMarkdownDatesExtension({
        syntax: fileType,
        pickDate: options.pickDate,
      }),
    );
  }

  if (fileType === "markdown") {
    extensions.push(createMarkdownInlineFormattingExtension());
    extensions.push(createMarkdownListEditingExtension());
  }

  if (fileType === "org") {
    extensions.push(
      createInlineFormattingKeymap({
        bold: { open: "*", close: "*" },
        italic: { open: "/", close: "/" },
      }),
    );
    extensions.push(createOrgListEditingExtension());
  }

  if (fileType === "markdown") {
    // Always install the document scanner facet so plugins can resolve the index.
    extensions.push(documentScannerFacet.of(markdownDocumentScanner));
    extensions.push(documentScanField);
  }

  if (fileType === "org") {
    extensions.push(documentScannerFacet.of(orgDocumentScanner));
    extensions.push(documentScanField);
  }

  const defaults = createNv3DefaultSlotExtensions(fileType, options);

  for (const slot of NV3_PLUGIN_SLOTS) {
    const injected = options.pluginSlots?.[slot] ?? [];
    const slotExtensions: Extension[] = [...defaults[slot], ...injected];
    extensions.push(runtime.slots[slot].of(slotExtensions));
  }

  if (fileType === "org" && !options.minimalPlugins) {
    extensions.push(
      createNv3OrgParserExtension({
        onChange: options.onOrgParseChange,
      }),
    );
    extensions.push(
      ...createOrgModeExtension({
        onTodoMenuOpen: options.onOrgTodoMenuOpen,
        onLinkOpen: options.onInlineLinkOpen
          ? (input) =>
              options.onInlineLinkOpen!({
                href: input.href,
                label: input.href,
                from: 0,
                to: 0,
                event: input.event,
                view: input.view,
              })
          : undefined,
      }),
    );
    extensions.push(createOrgSourceHighlightExtension());
    extensions.push(createOrgTablesExtension());
  }

  if (options.autocompleteProviders?.length) {
    extensions.push(
      createNv3AutocompleteExtension({
        providers: options.autocompleteProviders,
        filePath: options.filePath,
        activateOnTypingDelay: options.autocompleteActivateOnTypingDelay,
        onError: options.onAutocompleteError,
      }),
    );
  }

  if (options.extraExtensions?.length) {
    extensions.push(...options.extraExtensions);
  }

  return extensions;
}

export function createNv3EditorState(options: CreateNv3EditorStateOptions = {}): EditorState {
  return EditorState.create({
    doc: options.doc ?? "",
    selection: options.selection,
    extensions: createNv3EditorExtensions(options),
  });
}

export function reconfigureNv3Language(
  view: EditorView,
  runtime: Nv3EditorRuntime,
  fileType: Nv3FileType,
): void {
  view.dispatch({
    effects: runtime.language.reconfigure(languageExtensionFor(fileType)),
  });
}

export function reconfigureNv3Slot(
  view: EditorView,
  runtime: Nv3EditorRuntime,
  slot: Nv3PluginSlot,
  extensions: Extension[],
): void {
  view.dispatch({
    effects: runtime.slots[slot].reconfigure(extensions),
  });
}

export function reconfigureNv3Slots(
  view: EditorView,
  runtime: Nv3EditorRuntime,
  slots: Partial<Record<Nv3PluginSlot, Extension[]>>,
): void {
  const effects = Object.entries(slots).map(([slot, extensions]) =>
    runtime.slots[slot as Nv3PluginSlot].reconfigure(extensions ?? []),
  );

  if (effects.length === 0) return;

  view.dispatch({ effects });
}

export function createNv3MarkdownExtensions(
  options: Nv3MarkdownExtensionsOptions = {},
): Extension[] {
  return createNv3EditorExtensions({
    ...options,
    fileType: "markdown",
  });
}

export function createNv3MarkdownState(
  options: CreateNv3MarkdownStateOptions = {},
): EditorState {
  return EditorState.create({
    doc: options.doc ?? "",
    extensions: createNv3MarkdownExtensions(options),
  });
}

export { detectNv3FileType };
export type { Nv3FileType };

export {
  createMarkdownCodeFenceExtension,
  type Nv3CodeBlock,
  type Nv3CodeBlockIndex,
} from "./plugins/codeFences.ts";
export {
  createMarkdownCalloutExtension,
  getMarkdownCalloutBlocks,
  scanMarkdownCallouts,
  type MarkdownCalloutExtensionOptions,
  type Nv3MarkdownCalloutBlock,
} from "./plugins/callouts.ts";
export { createMarkdownBlockReferenceExtension, insertBlockReference } from "./plugins/blockReferences.ts";

export {
  createNv3AutocompleteExtension,
  type Nv3AutocompleteError,
  type Nv3AutocompleteExtensionOptions,
  type Nv3AutocompleteItem,
  type Nv3AutocompleteMatch,
  type Nv3AutocompleteProvider,
  type Nv3AutocompleteQueryInput,
} from "./plugins/autocomplete.ts";

export {
  createMarkdownFrontmatterExtension,
  defaultNv3FrontmatterSchema,
  extractFrontmatter,
  parseMarkdownFrontmatter,
  validateFrontmatter,
  type Nv3FrontmatterDiagnostic,
  type Nv3FrontmatterRange,
  type Nv3FrontmatterResult,
  type Nv3FrontmatterSchema,
} from "./plugins/frontmatter.ts";

export {
  createMarkdownLatexExtension,
  scanMarkdownLatex,
  type MarkdownLatexOptions,
  type Nv3LatexFragment,
  type Nv3LatexFragmentKind,
  type Nv3LatexIndex,
  type Nv3LatexPreviewMode,
} from "./plugins/latex.ts";

export {
  createMarkdownLinkExtension,
  type Nv3InlineLinkHrefInput,
  type Nv3InlineLinkOpenInput,
  type Nv3LinkIndex,
  type Nv3LinkKind,
  type Nv3LinkOccurrence,
  type Nv3WikilinkHrefInput,
  type Nv3WikilinkOpenInput,
} from "./plugins/links.ts";
export {
  nv3BlockReferenceMatches,
  nv3HeadingReferenceMatches,
  parseNv3WikilinkTarget,
  wikilinkDisplaySegments,
  type Nv3ParsedWikilinkTarget,
  type Nv3WikilinkDisplaySegments,
  type Nv3WikilinkReferenceKind,
} from "./plugins/wikilinks.ts";

export {
  resolveNv3BlockSection,
  resolveNv3MarkdownHeadingSection,
  resolveNv3OrgHeadingSection,
  resolveNv3SectionRange,
  type Nv3SectionFocus,
  type Nv3SectionRange,
} from "./sections.ts";

export {
  createMarkdownTransclusionExtension,
  detectStandaloneTransclusions,
  type MarkdownTransclusionOptions,
  type Nv3StandaloneTransclusionOccurrence,
  type Nv3TransclusionNestedStateInput,
  type Nv3TransclusionResolveInput,
  type Nv3TransclusionResolved,
  type Nv3TransclusionSaveInput,
} from "./plugins/transclusion.ts";

export {
  applyNv3TextSubstitutions,
  createNv3SubstitutionsExtension,
  nv3DefaultSubstitutionRules,
  type Nv3SubstitutionsOptions,
  type Nv3TextSubstitutionChange,
  type Nv3TextSubstitutionRule,
} from "./plugins/substitutions.ts";
export {
  createMarkdownListEditingExtension,
  indentMarkdownListItem,
  outdentMarkdownListItem,
} from "./plugins/listEditing.ts";
export { createMarkdownListPrefixesExtension } from "./plugins/listPrefixes.ts";
export {
  createMarkdownTablesExtension,
  createTablesExtension,
  markdownTableContextFromEventTarget,
  runMarkdownTableCommand,
  type MarkdownTableCommand,
  type MarkdownTableDomContext,
  type TableParser,
} from "./plugins/tables.ts";
export { createOrgTablesExtension } from "./plugins/orgTables.ts";
export {
  createNv3MarkdownScanExtension,
  getNv3MarkdownScanIndex,
  nv3MarkdownScanStateField,
  type Nv3MarkdownScanExtensionOptions,
} from "./plugins/markdownIndex.ts";
export {
  scanMarkdownDocument,
  scanMarkdownText,
  type Nv3MarkdownBlockIDOccurrence,
  type Nv3MarkdownCodeFenceBlock,
  type Nv3MarkdownHashTagOccurrence,
  type Nv3MarkdownHeadingOccurrence,
  type Nv3MarkdownHeadingTagOccurrence,
  type Nv3MarkdownInlineLinkOccurrence,
  type Nv3MarkdownLatexFragment,
  type Nv3MarkdownLatexFragmentKind,
  type Nv3MarkdownLinkKind,
  type Nv3MarkdownLinkOccurrence,
  type Nv3MarkdownMentionOccurrence,
  type Nv3MarkdownScanIndex,
  type Nv3MarkdownStandaloneTransclusionOccurrence,
  type Nv3MarkdownTaskCheckboxOccurrence,
} from "./plugins/markdownScanner.ts";
export { createMarkdownHeadingFoldingExtension } from "./plugins/headingFolding.ts";
export { createMarkdownHeadingPrefixesExtension } from "./plugins/headingPrefixes.ts";
export { createMarkdownMarksHidingExtension } from "./plugins/marksHiding.ts";
export {
  collectMarkdownLineUnwrapRanges,
  createMarkdownLineUnwrapExtension,
  type MarkdownLineUnwrapRange,
} from "./plugins/markdownLineUnwrap.ts";
export {
  collectOrgLineUnwrapRanges,
  createOrgLineUnwrapExtension,
} from "./plugins/orgLineUnwrap.ts";
export { createMarkdownHighlightExtension } from "./plugins/highlights.ts";
export {
  createMarkdownFrontmatterPropertiesExtension,
  nv3FrontmatterRows,
  nv3FrontmatterSegments,
  type Nv3FrontmatterRow,
  type Nv3FrontmatterSegment,
} from "./plugins/frontmatterProperties.ts";
export { beginNv3AnnotationComposer } from "./plugins/annotationComposer.ts";
export {
  addNv3AnnotationAt,
  addNv3Annotations,
  answerNv3Annotation,
  editNv3AnnotationNote,
  nv3AnnotationsChanged,
  createNv3AnnotationsExtension,
  findNv3AnnotationAnchor,
  listNv3Annotations,
  nv3AnnotationSpecs,
  removeNv3Annotations,
  revealNv3Annotation,
  NV3_ANNOTATION_COLORS,
  NV3_ANNOTATION_STYLES,
  type Nv3AnnotationAddResult,
  type Nv3AnnotationAnchor,
  type Nv3AnnotationAuthor,
  type Nv3AnnotationColor,
  type Nv3AnnotationInput,
  type Nv3AnnotationRemoveFilter,
  type Nv3AnnotationSnapshot,
  type Nv3AnnotationSpec,
  type Nv3AnnotationStyle,
  type Nv3AnnotationTarget,
} from "./plugins/annotations.ts";
export { createMarkdownHorizontalRuleExtension } from "./plugins/horizontalRules.ts";
export { createMarkdownMentionExtension } from "./plugins/mentions.ts";
export {
  adjustMarkdownTimestampsByDays,
  buildShiftMarkdownTimestampsTransaction,
  createMarkdownDatesExtension,
  formatMarkdownTimestamp,
  isValidISODate,
  openOrInsertMarkdownTimestamp,
  parseMarkdownTimestamp,
  scanMarkdownTimestamps,
  shiftISODate,
  type MarkdownDatesExtensionOptions,
  type Nv3DatePickerSelection,
  type Nv3MarkdownDatePickerRequest,
  type Nv3MarkdownTimestampKind,
  type Nv3MarkdownTimestampOccurrence,
  type Nv3ParsedMarkdownTimestamp,
} from "./plugins/dates.ts";
export {
  createMarkdownFootnoteExtension,
  getMarkdownFootnoteIndex,
  scanMarkdownFootnotes,
  type Nv3MarkdownFootnoteDefinition,
  type Nv3MarkdownFootnoteIndex,
  type Nv3MarkdownFootnoteReference,
} from "./plugins/footnotes.ts";
export {
  createInlineFormattingKeymap,
  createMarkdownInlineFormattingExtension,
  createToggleDelimitedMarkupCommand,
  toggleMarkdownBold,
  toggleMarkdownHighlight,
  toggleMarkdownItalic,
  type Nv3InlineFormattingKeymapOptions,
  type Nv3InlineMarkupDelimiters,
} from "./plugins/inlineFormatting.ts";
export {
  prefixMarkdownSelectionLines,
  quoteMarkdownSelection,
  unquoteMarkdownSelection,
  type MarkdownSelectionLinePrefixOptions,
} from "./plugins/blockquoteCommands.ts";
export {
  detectMarkdownTaskCheckboxes,
  type Nv3TaskCheckboxOccurrence,
} from "./plugins/taskCheckboxes.ts";
export { nv3NotionEditorTheme } from "./theme/notionTheme.ts";
export {
  applyNv3InspectorStylesheet,
  applyNv3UserStylesheet,
} from "./theme/stylesheet.ts";

export {
  createMarkdownTagExtension,
  type Nv3TagIndex,
  type Nv3TagOccurrence,
} from "./plugins/markdownTags.ts";
export {
  createMarkdownTodoHeadingsExtension,
  resolveMarkdownHeaderStates,
  scanMarkdownHeadingStates,
  DEFAULT_MARKDOWN_HEADER_STATES,
  type Nv3MarkdownHeadingStateOccurrence,
} from "./plugins/todoHeadings.ts";

export {
  createNv3OrgParserExtension,
  getNv3OrgParseResult,
  nv3OrgParseStateField,
  orgDocumentScanner,
  type Nv3OrgParserExtensionOptions,
} from "./plugins/orgIndex.ts";

export { createOrgModeExtension, TODO_STATES, type OrgModeOptions } from "./org/orgExtension.ts";

export {
  createOrgListEditingExtension,
  continueOrgList,
  indentOrgListItem,
  outdentOrgListItem,
  deleteOrgListItemBackward,
} from "./plugins/orgListEditing.ts";
export { createAutoLinksExtension } from "./plugins/autoLinks.ts";

export {
  createMarkdownImagePreviewExtension,
  type MarkdownImagePreviewOptions,
} from "./plugins/imagePreview.ts";

export {
  createMarkdownCalcExtension,
  getMarkdownCalcDocument,
  getMarkdownCalcEvaluation,
  scanMarkdownCalcDocument,
  type MarkdownCalcExtensionOptions,
  type Nv3MarkdownCalcDocument,
  type Nv3MarkdownCalcEvaluation,
  type Nv3MarkdownCalcFence,
  type Nv3MarkdownCalcFenceOutput,
  type Nv3MarkdownCalcInlineEvaluation,
  type Nv3MarkdownCalcInlineExpression,
} from "./plugins/calc.ts";

export {
  createCalcRuntimeScope,
  evaluateCalcBlock,
  evaluateCalcExpression,
  evaluateCalcStatement,
  formatCalcRuntimeValue,
  type CalcBlockEvaluation,
  type CalcBlockQueryResult,
  type CalcEvaluationFailure,
  type CalcEvaluationResult,
  type CalcEvaluationSuccess,
  type CalcRuntimeError,
  type CalcRuntimeScope,
  type CalcRuntimeValue,
} from "./calc/runtime.ts";

export type {
  Scalar as CalcScalar,
  Rational as CalcRational,
  Complex as CalcComplex,
  Quantity as CalcQuantity,
  Numeric as CalcNumeric,
} from "./calc/numeric.ts";
export type { Symbolic as CalcSymbolic, CalcSymbol, SymbolicExpression as CalcSymbolicExpression } from "./calc/symbolic.ts";
export type { CalcUnit } from "./calc/units.ts";
export {
  calcCatalog,
  calcEntry,
  searchCalcCatalog,
  type CalcCatalogEntry,
  type CalcDiscoveryType,
} from "./calc/catalog.ts";
export { openCalcExplorer, closeCalcExplorer, applyCalcHelpInsertion, dismissCalcHelp } from "./plugins/calcDiscovery.ts";
export {
  isCalcPlot,
  formatCalcPresentation,
  type CalcPlot,
  type CalcPlotKind,
  type CalcPlotPoint,
  type CalcPresentation,
} from "./calc/plot.ts";

export {
  parseCalcBlock,
  parseCalcExpression,
  parseCalcStatement,
  type CalcBlockLine,
  type CalcBlockLineKind,
  type CalcBlockParseResult,
  type CalcBinaryExpression,
  type CalcBooleanLiteral,
  type CalcCallExpression,
  type CalcDiagnostic,
  type CalcExpression,
  type CalcExpressionParseResult,
  type CalcExpressionStatement,
  type CalcFunctionDefinitionStatement,
  type CalcIdentifierExpression,
  type CalcListExpression,
  type CalcListComprehensionExpression,
  type CalcMemberExpression,
  type CalcNullLiteral,
  type CalcNumberLiteral,
  type CalcQuantityLiteral,
  type CalcImaginaryLiteral,
  type CalcPresentationExpression,
  type CalcPresenter,
  type CalcSymbolDeclaration,
  type CalcParameter,
  type CalcPipeExpression,
  type CalcPipeStage,
  type CalcRange,
  type CalcReferenceExpression,
  type CalcStatement,
  type CalcStatementParseResult,
  type CalcStringLiteral,
  type CalcUnaryExpression,
  type CalcValueDefinitionStatement,
} from "./calc/parser.ts";

export {
  parseOrgDocument,
  parseOrgText,
  type Nv3OrgChecklistState,
  type Nv3OrgDiagnostic,
  type Nv3OrgExcludedRange,
  type Nv3OrgFootnoteDefinition,
  type Nv3OrgFootnoteReference,
  type Nv3OrgHeading,
  type Nv3OrgHeadingTag,
  type Nv3OrgLink,
  type Nv3OrgLinkType,
  type Nv3OrgListItem,
  type Nv3OrgListKind,
  type Nv3OrgMarkup,
  type Nv3OrgMarkupKind,
  type Nv3OrgParseCounts,
  type Nv3OrgParseResult,
  type Nv3OrgPropertiesDrawer,
  type Nv3OrgPropertyEntry,
  type Nv3OrgSourceBlock,
  type Nv3OrgSpecialBlock,
  type Nv3OrgSpecialBlockKind,
  type Nv3OrgTable,
  type Nv3OrgTableCell,
  type Nv3OrgTableRow,
  type Nv3OrgTimestamp,
} from "./org/parser.ts";

export {
  collectMarkdownHeadingSections,
  collectMarkdownTocHeadings,
  collectMarkdownOutlineHeadings,
  collectOrgTocHeadings,
  collectOrgOutlineHeadings,
  resolveActiveTocHeadingId,
  type Nv3MarkdownHeadingSection,
  type Nv3TocHeading,
  type Nv3OutlineHeading,
} from "./plugins/headings.ts";

export { Nv3TableOfContents, type Nv3TableOfContentsProps } from "./react/TableOfContents.tsx";

// ── Language-agnostic infrastructure ──────────────────────────────────────

export {
  documentScanField,
  documentScannerFacet,
  getDocumentScanIndex,
  resolveDocumentScanIndex,
  EMPTY_SCAN_INDEX,
  type DocumentScanIndex,
  type DocumentScanner,
  type TagOccurrence,
  type MentionOccurrence,
  type TaskOccurrence,
  type HeadingOccurrence,
  type BlockIDOccurrence,
  type LinkKind,
  type LinkOccurrence,
  type InlineLinkOccurrence,
  type CodeBlockOccurrence,
  type TransclusionOccurrence,
  type LatexFragmentKind,
  type LatexFragmentOccurrence,
} from "./plugins/documentIndex.ts";

export { decorationPlugin, trackedDecorationPlugin } from "./plugins/scanPlugin.ts";
export { selectionTouchesRange, resolveEventElement, focusEditorWithoutScroll, asPlainObject } from "./plugins/viewUtils.ts";
export {
  isEscaped,
  isDigit,
  isWordLike,
  isWhitespace,
  resetIfStalled,
  hashHue,
  findInlineCodeRanges,
  rangeContainsIndex,
  hasRangeOverlap,
  detectFrontmatterBounds,
  type TextRange,
  type FrontmatterBounds,
} from "./plugins/scanUtils.ts";
export { markdownDocumentScanner } from "./plugins/markdownScanner.ts";
export {
  createNv3InteractionStateExtension,
  getNv3InteractionMode,
  isNv3InteractionActive,
  nv3InteractionModeChanged,
  nv3InteractionModeField,
  resolveNv3InteractionMode,
  setNv3InteractionMode,
  setNv3InteractionModeEffect,
  type Nv3InteractionMode,
} from "./plugins/interactionState.ts";
export {
  currentTimeLocal,
  formatTimestamp,
  humanDateLabelForISODate,
  normalizeTimestampTime,
  parseISODateUTC,
  parseTimestampDateContent,
  parseTimestampDateTimeContent,
  parseTimestampLiteral,
  todayISODateLocal,
  weekdayForISODate,
  type ParsedTimestamp,
  type TimestampDateTimeValue,
  type TimestampKind,
} from "./plugins/dateUtils.ts";
