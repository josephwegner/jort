// Locale-aware, case-insensitive collation is captured by the host.
// alphabeticalOrder is a stable ascending permutation of logical line indices.
export default async function(input) {
  if (!input.content) return {output: ""};
  const separator = input.content.match(/\r\n|\r|\n/)?.[0] ?? "\n";
  const hasTerminalSeparator = /(?:\r\n|\r|\n)$/.test(input.content);
  const lines = input.content.split(/\r\n|\r|\n/);
  if (hasTerminalSeparator) lines.pop();
  const order = input.analysis?.alphabeticalOrder;
  if (!Array.isArray(order) || order.length !== lines.length ||
      new Set(order).size !== lines.length ||
      order.some(index => !Number.isInteger(index) || index < 0 || index >= lines.length)) {
    return {error: "Captured locale alphabetical order is unavailable or invalid."};
  }
  const sorted = order.filter(index => /[^\s\u0085]/.test(lines[index])).map(index => lines[index]);
  const blanks = lines.filter(line => /^[\s\u0085]*$/.test(line));
  return {output: sorted.concat(blanks).join(separator) +
    (hasTerminalSeparator ? separator : "")};
}
