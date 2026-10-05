// English defaults: edit this list to match your preferred title style.
// Raw text casing can change code and URL paths.
const MINOR_WORDS = new Set([
  "a", "an", "the", "and", "but", "or", "nor", "as", "at", "by", "for",
  "from", "in", "into", "of", "on", "onto", "per", "to", "up", "via", "with"
]);
const WORD = /\p{L}[\p{L}\p{M}\p{N}]*(?:['’][\p{L}\p{M}]+)*/gu;

function titleLine(line) {
  const words = Array.from(line.matchAll(WORD));
  let index = 0;
  return line.replace(WORD, word => {
    const firstOrLast = index === 0 || index === words.length - 1;
    index += 1;
    // Preserve all-uppercase acronyms, including a possessive suffix.
    const stem = word.replace(/['’]s$/i, "");
    if (Array.from(stem).length > 1 && stem === stem.toUpperCase() &&
        stem !== stem.toLowerCase()) return word;
    const lower = word.toLowerCase();
    if (!firstOrLast && MINOR_WORDS.has(lower)) return lower;
    const characters = Array.from(lower);
    characters[0] = characters[0].toUpperCase();
    return characters.join("");
  });
}

export default async function(input) {
  return {output: input.content.split(/(\r\n|\r|\n)/).map((part, index) =>
    index % 2 === 1 ? part : titleLine(part)).join("")};
}
