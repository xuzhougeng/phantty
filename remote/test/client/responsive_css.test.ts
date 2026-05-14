import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const responsiveCssUrl = new URL("../../src/client/styles/responsive.css", import.meta.url);

test("mobile drawer keeps remote tabs usable on short screens", async () => {
  const css = await readFile(responsiveCssUrl, "utf8");
  const panelRule = declarationsForSelector(css, ".remote-tabs-panel").join("\n");
  const tabsRule = declarationsForSelector(css, ".remote-tabs").join("\n");

  assert.match(panelRule, /(?:flex:\s*0\s+0\s+auto|flex-shrink:\s*0)\s*;/);
  assert.match(tabsRule, /max-height\s*:/);
  assert.match(tabsRule, /overflow-y:\s*auto\s*;/);
});

function declarationsForSelector(css: string, selector: string): string[] {
  const rulePattern = /([^{}]+)\{([^{}]*)\}/g;
  const matches: string[] = [];
  for (const match of css.matchAll(rulePattern)) {
    const selectors = match[1]
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean);
    if (selectors.includes(selector)) matches.push(match[2]);
  }
  if (matches.length > 0) return matches;
  throw new Error(`Missing CSS rule for ${selector}`);
}
