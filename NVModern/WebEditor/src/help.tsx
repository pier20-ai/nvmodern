import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { bridge } from "./bridge.ts";
import type { HelpTopic } from "./lib/help/model.ts";
import "./help/help.css";

interface Selection {
  topic?: HelpTopic;
  providerTitle?: string;
  canInsert?: boolean;
  allowsMultiline?: boolean;
}
function HelpDetail() {
  const [selection, setSelection] = useState<Selection>({});
  useEffect(() => {
    const unsubscribe = bridge.onCommand((command, payload) => {
      if (command === "help.showTopic") setSelection(payload as Selection);
      if (command === "setHostAppearance") {
        document.documentElement.dataset.theme = (payload as { colorScheme: string }).colorScheme;
      }
    });
    const keydown = (event: KeyboardEvent) => {
      if (event.key === "Escape") { event.preventDefault(); bridge.emit("help.close"); }
    };
    window.addEventListener("keydown", keydown);
    bridge.sendReady();
    return () => { unsubscribe(); window.removeEventListener("keydown", keydown); };
  }, []);
  const { topic, canInsert, allowsMultiline } = selection;
  useEffect(() => { window.scrollTo(0, 0); }, [topic?.id]);
  if (!topic) return <main className="empty"><p>No matching topics</p><span>Try another search or category.</span></main>;
  const insert = (id: string) => bridge.emit("help.insert", { topicID: topic.id, actionID: id });
  const button = (id: string) => {
    const action = topic.insertions.find((action) => action.id === id);
    if (!action || !canInsert) return null;
    const disabled = !allowsMultiline && action.template.includes("\n");
    return <button disabled={disabled} title={disabled ? "This example needs a calc block." : undefined}
      onClick={() => insert(id)}>{action.label}<span aria-hidden="true">↗</span></button>;
  };
  return <main key={topic.id}>
    <p className="eyebrow">{selection.providerTitle} <span> / </span> {topic.category}</p>
    <h1>{topic.title}</h1>
    <p className="summary">{topic.summary}</p>
    {!!topic.signatures.length && <section aria-label="Signatures" className="signatures">
      {topic.signatures.map((signature, i) => <code key={i}>{signature}</code>)}
    </section>}
    {!!topic.aliases.length && <p className="aliases">Also available as {topic.aliases.map((alias, i) =>
      <React.Fragment key={alias}>{i > 0 && ", "}<code>{alias}</code></React.Fragment>)}</p>}
    {!!topic.shortcuts?.length && <section aria-label="Shortcuts" className="shortcuts">
      {topic.shortcuts.map((shortcut, i) => <div key={i}><kbd>{shortcut.keys}</kbd><span>{shortcut.action}</span></div>)}
    </section>}
    {button("template")}
    {!!topic.examples.length && <section className="examples"><h2>Examples</h2>
      {topic.examples.map((example, i) => <article key={i}>
        <pre><code>{example.code}</code></pre>
        {example.result !== undefined && <div className="result"><span aria-label="Result">→</span><code>{example.result}</code></div>}
        {button(`example-${i}`)}
      </article>)}
    </section>}
    {!canInsert && !!topic.insertions.length && <p className="hint">Open help from an editable expression to insert templates and examples.</p>}
  </main>;
}
createRoot(document.getElementById("root")!).render(<HelpDetail />);
