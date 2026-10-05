// Locale-aware ranks come from the host: one per logical line, equal for ties.
// Reverse the rank comparison, never the items themselves (which reverses ties).
export default async function(input) {
  if (!input.content) return {output: ""};
  const separator = input.content.match(/\r\n|\r|\n/)?.[0] ?? "\n";
  const hasTerminalSeparator = /(?:\r\n|\r|\n)$/.test(input.content);
  const lines = input.content.split(/\r\n|\r|\n/);
  if (hasTerminalSeparator) lines.pop();
  const ranks = input.analysis?.alphabeticalRanks;
  if (!Array.isArray(ranks) || ranks.length !== lines.length ||
      ranks.some(rank => !Number.isInteger(rank) || rank < 0)) {
    return {error: "Captured locale alphabetical ranks are unavailable or invalid."};
  }
  const items = lines.map((text, index) => ({text, index, rank: ranks[index]}));
  items.sort((left, right) => {
    const leftBlank = /^[\s\u0085]*$/.test(left.text);
    const rightBlank = /^[\s\u0085]*$/.test(right.text);
    if (leftBlank !== rightBlank) return leftBlank ? 1 : -1;
    if (!leftBlank && left.rank !== right.rank) return right.rank - left.rank;
    return left.index - right.index;
  });
  return {output: items.map(item => item.text).join(separator) +
    (hasTerminalSeparator ? separator : "")};
}
