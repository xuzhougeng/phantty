import test from "node:test";
import assert from "node:assert/strict";

import { normalizeLayout } from "../../src/client/layout";

test("normalizeLayout preserves AI chat pseudo-surface metadata", () => {
  const layout = normalizeLayout({
    type: "layout",
    activeTab: 3,
    tabs: [
      {
        index: 3,
        title: "DeepSeek",
        focusedSurfaceId: "ai-chat-3",
        surfaces: [
          {
            id: "aichat0000000003",
            kind: "ai_chat",
            readOnly: false,
            title: "DeepSeek",
            snapshot: "You:\r\nhi\r\n\r\nAI:\r\nhello",
            requestInflight: true,
            requestStopping: false,
            cols: 120,
            rows: 30,
          },
        ],
      },
    ],
  });

  assert.equal(layout.activeTab, 3);
  assert.equal(layout.tabs[0]?.surfaces[0]?.kind, "ai_chat");
  assert.equal(layout.tabs[0]?.surfaces[0]?.readOnly, false);
  assert.equal(layout.tabs[0]?.surfaces[0]?.snapshot, "You:\r\nhi\r\n\r\nAI:\r\nhello");
  assert.equal(layout.tabs[0]?.surfaces[0]?.requestInflight, true);
  assert.equal(layout.tabs[0]?.surfaces[0]?.requestStopping, false);
});
