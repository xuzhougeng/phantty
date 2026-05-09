export type StickyMods = { ctrl: boolean; alt: boolean };

export function ctrlLetter(letter: string): string | null {
  const lower = letter.toLowerCase();
  if (lower.length !== 1 || lower < "a" || lower > "z") return null;
  return String.fromCharCode(lower.charCodeAt(0) - 96);
}

export function applyStickyMods(text: string, mods: StickyMods): string {
  if (mods.ctrl && text.length === 1) {
    return ctrlLetter(text) ?? text;
  }
  if (mods.alt && text.length === 1) {
    return `\x1b${text}`;
  }
  return text;
}

export function keyToSequence(key: string): string | null {
  switch (key) {
    case "esc": return "\x1b";
    case "tab": return "\t";
    case "up": return "\x1b[A";
    case "down": return "\x1b[B";
    case "right": return "\x1b[C";
    case "left": return "\x1b[D";
    case "bksp": return "\x7f";
    case "enter": return "\r";
    default: return null;
  }
}
