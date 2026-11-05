import { describe, expect, it } from "bun:test";
import { applyNv3InspectorStylesheet, applyNv3UserStylesheet } from "./stylesheet.ts";

/** Just enough of the DOM for the stylesheet helpers: one <head> of nodes. */
class FakeNode {
  id = "";
  textContent: string | null = "";
  parentNode: FakeNode | null = null;
  children: FakeNode[] = [];
  attributes = new Map<string, string>();

  setAttribute(name: string, value: string) {
    this.attributes.set(name, value);
  }

  insertBefore(node: FakeNode, anchor: FakeNode | null) {
    node.parentNode = this;
    const index = anchor ? this.children.indexOf(anchor) : -1;
    if (index === -1) this.children.push(node);
    else this.children.splice(index, 0, node);
    return node;
  }

  remove() {
    if (!this.parentNode) return;
    this.parentNode.children = this.parentNode.children.filter((child) => child !== this);
    this.parentNode = null;
  }
}

function fakeDocument() {
  const head = new FakeNode();
  const doc = {
    head,
    documentElement: head,
    createElement: () => new FakeNode(),
    getElementById: (id: string) => head.children.find((child) => child.id === id) ?? null,
  };
  return { head, doc: doc as unknown as Document };
}

const ids = (head: FakeNode) => head.children.map((child) => child.id);

describe("theme stylesheets", () => {
  it("keeps the base theme ahead of the per-document sheet when it arrives later", () => {
    const { head, doc } = fakeDocument();
    applyNv3InspectorStylesheet(":root { --a: 1; }", doc);
    applyNv3UserStylesheet(":root { --a: 2; }", doc);
    expect(ids(head)).toEqual(["nv3-user-theme-styles", "nv3-inspector-theme-styles"]);
  });

  it("re-inserts a cleared base theme ahead of the per-document sheet", () => {
    const { head, doc } = fakeDocument();
    applyNv3UserStylesheet(":root { --a: 2; }", doc);
    applyNv3InspectorStylesheet(":root { --a: 1; }", doc);
    applyNv3UserStylesheet("", doc);
    expect(ids(head)).toEqual(["nv3-inspector-theme-styles"]);
    applyNv3UserStylesheet(":root { --a: 3; }", doc);
    expect(ids(head)).toEqual(["nv3-user-theme-styles", "nv3-inspector-theme-styles"]);
  });

  it("updates an existing sheet in place", () => {
    const { head, doc } = fakeDocument();
    const first = applyNv3UserStylesheet(":root { --a: 1; }", doc);
    const second = applyNv3UserStylesheet(":root { --a: 2; }", doc);
    expect(second).toBe(first);
    expect(head.children).toHaveLength(1);
    expect(head.children[0]?.textContent).toBe(":root { --a: 2; }");
  });
});
