// A heuristic, not a grammar parser. Edit the abbreviation list for your prose.
// Internal casing (iPhone, NASA) stays intact. Code/URL starts may be affected.
const ABBREVIATIONS = new Set([
  "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc",
  "e.g", "i.e", "approx", "fig", "no", "dept", "inc", "ltd", "a.m", "p.m"
]);
const CLOSING_MARKS = new Set(['"', "'", "”", "’", ")", "]", "}"]);
const LETTER = /\p{L}/u;

function endsSentence(text, index) {
  const punctuation = text[index];
  if (punctuation === "!" || punctuation === "?") return true;
  if (punctuation !== ".") return false;
  const before = text.slice(Math.max(0, index - 80), index);
  const word = before.match(/([\p{L}.]+)$/u)?.[1]?.toLowerCase() ?? "";
  if (ABBREVIATIONS.has(word)) return false;
  // Initials and dotted initialisms (A., U.S.) usually continue the sentence.
  if (/^(?:\p{L}\.)*\p{L}$/u.test(word)) return false;
  const next = text[index + 1];
  // Decimal points and periods within URLs/identifiers do not end sentences.
  if (next && !/\s/.test(next) && !CLOSING_MARKS.has(next) &&
      next !== "." && next !== "!" && next !== "?") return false;
  return true;
}

export default async function(input) {
  let capitalizeNext = true;
  let output = "";
  let offset = 0;
  for (const character of input.content) {
    if (LETTER.test(character) && capitalizeNext) {
      output += character.toUpperCase();
      capitalizeNext = false;
    } else {
      output += character;
      // Leading digits can precede the first letter without consuming its case.
    }
    if (endsSentence(input.content, offset)) capitalizeNext = true;
    offset += character.length;
  }
  return {output};
}
