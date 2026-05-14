import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { parseAiChatTranscript } from "../../src/client/ai_chat_transcript";

describe("AI chat transcript parsing", () => {
  it("splits user and assistant blocks into chat messages", () => {
    assert.deepEqual(parseAiChatTranscript("You:\nhello\n\nAI:\nhi there"), [
      { role: "user", label: "You", content: "hello" },
      { role: "assistant", label: "AI", content: "hi there" },
    ]);
  });

  it("accepts CRLF transcripts from the relay", () => {
    assert.deepEqual(parseAiChatTranscript("You:\r\nrun ls\r\n\r\nAI:\r\nDone\r\n"), [
      { role: "user", label: "You", content: "run ls" },
      { role: "assistant", label: "AI", content: "Done" },
    ]);
  });

  it("keeps unknown transcript text as an assistant message", () => {
    assert.deepEqual(parseAiChatTranscript("ready"), [
      { role: "assistant", label: "AI", content: "ready" },
    ]);
  });
});
