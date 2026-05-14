export type AiChatMessage = {
  role: "user" | "assistant" | "tool";
  label: string;
  content: string;
};

const speakerPattern = /^(You|User|AI|Assistant|Tool):\s*$/i;

export function parseAiChatTranscript(transcript: string): AiChatMessage[] {
  const lines = transcript.replace(/\r\n/g, "\n").split("\n");
  const messages: AiChatMessage[] = [];
  let current: AiChatMessage | null = null;
  let contentLines: string[] = [];

  for (const line of lines) {
    const match = speakerPattern.exec(line.trim());
    if (match) {
      flushCurrent();
      current = {
        role: roleForLabel(match[1]),
        label: normalizedLabel(match[1]),
        content: "",
      };
      contentLines = [];
      continue;
    }

    if (current) {
      contentLines.push(line);
    }
  }

  flushCurrent();

  if (messages.length === 0) {
    const content = transcript.trim();
    return content ? [{ role: "assistant", label: "AI", content }] : [];
  }

  return messages;

  function flushCurrent(): void {
    if (!current) return;
    current.content = trimBlankLines(contentLines).join("\n");
    messages.push(current);
  }
}

function roleForLabel(label: string): AiChatMessage["role"] {
  const lower = label.toLowerCase();
  if (lower === "you" || lower === "user") return "user";
  if (lower === "tool") return "tool";
  return "assistant";
}

function normalizedLabel(label: string): string {
  const lower = label.toLowerCase();
  if (lower === "you" || lower === "user") return "You";
  if (lower === "tool") return "Tool";
  return "AI";
}

function trimBlankLines(lines: string[]): string[] {
  let start = 0;
  let end = lines.length;
  while (start < end && lines[start].trim() === "") start += 1;
  while (end > start && lines[end - 1].trim() === "") end -= 1;
  return lines.slice(start, end);
}
