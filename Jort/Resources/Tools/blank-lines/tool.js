export default async function(input) {
  // Each even part is a line, followed by its exact separator (when present).
  const parts = input.content.split(/(\r\n|\r|\n)/);
  const retained = [];
  for (let index = 0; index < parts.length; index += 2) {
    if (/^[\s\u0085]*$/.test(parts[index])) continue;
    retained.push({text: parts[index], separator: parts[index + 1] ?? ""});
  }
  if (!retained.length) return {output: ""};
  const terminalSeparator = input.content.match(/(\r\n|\r|\n)$/)?.[0] ?? "";
  // The last retained line inherits terminal-newline presence even when the
  // original last line was blank. Other retained separators stay unchanged.
  retained[retained.length - 1].separator = terminalSeparator;
  return {output: retained.map(line => line.text + line.separator).join("")};
}
