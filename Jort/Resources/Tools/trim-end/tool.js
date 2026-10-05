// Horizontal whitespace: tabs, Unicode space separators, and BOM.
// Vertical controls and Unicode line separators are retained.
const EDGE_WHITESPACE = /[\t\p{Zs}\uFEFF]+$/gu;

export default async function(input) {
  // Captured separator groups keep mixed CRLF/CR/LF boundaries exactly.
  const output = input.content.split(/(\r\n|\r|\n)/).map((part, index) =>
    index % 2 === 1 ? part : part.replace(EDGE_WHITESPACE, "")).join("");
  return {output};
}
