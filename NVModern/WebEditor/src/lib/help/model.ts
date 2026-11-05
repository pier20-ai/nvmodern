/** Portable help content. Hosts own navigation; renderers own rich presentation. */
export interface HelpTopic {
  id: string;
  title: string;
  category: string;
  summary: string;
  keywords: readonly string[];
  signatures: readonly string[];
  aliases: readonly string[];
  examples: readonly { code: string; result?: string }[];
  insertions: readonly { id: string; label: string; template: string }[];
  /** Key bindings for this topic; absent for providers (like calc) that teach syntax instead. */
  shortcuts?: readonly { keys: string; action: string }[];
}
export interface HelpProvider {
  id: string;
  title: string;
  topics: readonly HelpTopic[];
}
export interface HelpOpenRequest {
  providerID: string;
  token: string;
  canInsert: boolean;
  allowsMultiline: boolean;
  anchor: { x: number; y: number; width: number; height: number };
}
