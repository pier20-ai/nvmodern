import { renderCalcCatalogReference } from "../src/lib/calc/catalog.ts";
await Bun.write(new URL("../src/lib/calc/REFERENCE.md", import.meta.url), renderCalcCatalogReference());
