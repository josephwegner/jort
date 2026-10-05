// Edit direction: 1 is ascending; -1 is descending.
const DIRECTION = -1;

function firstFiniteNumber(line) {
  const numbers = line.match(/[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?/g) ?? [];
  for (const token of numbers) {
    const value = Number(token);
    if (Number.isFinite(value)) return value;
  }
  return null;
}

export default async function(input) {
  if (!input.content) return {output: ""};
  const separator = input.content.match(/\r\n|\r|\n/)?.[0] ?? "\n";
  const hasTerminalSeparator = /(?:\r\n|\r|\n)$/.test(input.content);
  const lines = input.content.split(/\r\n|\r|\n/);
  if (hasTerminalSeparator) lines.pop();
  const items = lines.map((text, index) => {
    const number = firstFiniteNumber(text);
    // Numbered lines, unnumbered nonblank lines, then blanks in all directions.
    const group = /^[\s\u0085]*$/.test(text) ? 2 : number === null ? 1 : 0;
    return {text, index, number, group};
  });
  items.sort((left, right) => {
    if (left.group !== right.group) return left.group - right.group;
    if (left.group === 0 && left.number !== right.number) {
      return (left.number < right.number ? -1 : 1) * DIRECTION;
    }
    // Explicit tie-breaking keeps equal values and all nonnumeric items stable.
    return left.index - right.index;
  });
  return {output: items.map(item => item.text).join(separator) +
    (hasTerminalSeparator ? separator : "")};
}
