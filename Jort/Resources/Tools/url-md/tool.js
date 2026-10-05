// Bare URLs use their host/path as the label and retain query/fragment in the
// destination. No URLs are fetched. This bounded Markdown scanner deliberately
// keeps existing links, images, reference links, code and autolinks intact.
const TRAILING_PUNCTUATION = ".,;:!?";
const CLOSING_PAIRS = {")": "(", "]": "[", "}": "{"};

function blockProtection(content) {
  const protectedCharacters = new Uint8Array(content.length);
  const referenceLabels = new Set();
  let fence = null;
  let offset = 0;
  const lines = content.split(/(\r\n|\r|\n)/);
  for (let index = 0; index < lines.length; index += 2) {
    const line = lines[index];
    const separator = lines[index + 1] ?? "";
    let protect = false;
    if (fence) {
      protect = true;
      const closing = line.match(/^ {0,3}(`{3,}|~{3,})[ \t]*$/);
      if (closing && closing[1][0] === fence.character &&
          closing[1].length >= fence.length) fence = null;
    } else {
      const opening = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
      if (opening && !(opening[1][0] === "`" && opening[2].includes("`"))) {
        fence = {character: opening[1][0], length: opening[1].length};
        protect = true;
      }
      if (/^(?: {4}|\t)/.test(line)) protect = true;
      const reference = line.match(/^ {0,3}\[([^\]]+)\]:[ \t]*/);
      if (reference) {
        referenceLabels.add(normalizeLabel(reference[1]));
        protect = true;
      }
    }
    if (protect) protectedCharacters.fill(1, offset, offset + line.length + separator.length);
    offset += line.length + separator.length;
  }
  return {protectedCharacters, referenceLabels};
}

function normalizeLabel(label) {
  return label.trim().replace(/\s+/g, " ").toLowerCase();
}

function pairedEnds(text, opening, closing) {
  // Precompute once, so repeated unmatched brackets do not cause rescanning.
  const ends = new Map();
  const stack = [];
  for (let index = 0; index < text.length; index += 1) {
    if (text[index] === "\\") { index += 1; continue; }
    if (text[index] === opening) stack.push(index);
    if (text[index] === closing && stack.length) ends.set(stack.pop(), index + 1);
  }
  return ends;
}

function existingLinkEnd(text, start, referenceLabels, brackets, parentheses) {
  const bracket = text[start] === "!" ? start + 1 : start;
  if (text[bracket] !== "[") return -1;
  const end = brackets.get(bracket) ?? -1;
  if (end < 0) return -1;
  if (text[end] === "(") return parentheses.get(end) ?? -1;
  if (text[end] === "[") {
    const referenceEnd = brackets.get(end) ?? -1;
    if (referenceEnd > 0) return referenceEnd;
  }
  const label = text.slice(bracket + 1, end - 1);
  return referenceLabels.has(normalizeLabel(label)) ? end : -1;
}

function codeSpanEnd(text, start) {
  let length = 1;
  while (text[start + length] === "`") length += 1;
  let index = start + length;
  while (index < text.length) {
    if (text[index] !== "`") { index += 1; continue; }
    const runStart = index;
    while (text[index] === "`") index += 1;
    if (index - runStart === length) return index;
  }
  return -1; // Unmatched backticks are ordinary Markdown text.
}

function trimURL(candidate) {
  const counts = {};
  for (const character of candidate) counts[character] = (counts[character] ?? 0) + 1;
  let end = candidate.length;
  while (end > 0) {
    const last = candidate[end - 1];
    if (TRAILING_PUNCTUATION.includes(last)) { end -= 1; continue; }
    const opening = CLOSING_PAIRS[last];
    if (opening) {
      if ((counts[last] ?? 0) > (counts[opening] ?? 0)) {
        counts[last] -= 1;
        end -= 1;
        continue;
      }
    }
    break;
  }
  return candidate.slice(0, end);
}

function urlLabel(url) {
  const withoutScheme = url.replace(/^https?:\/\//i, "");
  return withoutScheme.split(/[?#]/)[0] || withoutScheme;
}

function markdownLabel(text) {
  return text.replace(/([\\[\]])/g, "\\$1");
}

function markdownDestination(url) {
  // Escape balanced URL parentheses so the Markdown destination stays intact.
  return url.replace(/([\\()])/g, "\\$1");
}

export default async function(input) {
  const text = input.content;
  const {protectedCharacters, referenceLabels} = blockProtection(text);
  const brackets = pairedEnds(text, "[", "]");
  const parentheses = pairedEnds(text, "(", ")");
  let output = "";
  let index = 0;
  while (index < text.length) {
    if (protectedCharacters[index]) { output += text[index++]; continue; }
    if (text[index] === "\\") {
      output += text.slice(index, index + 2);
      index += Math.min(2, text.length - index);
      continue;
    }
    if (text[index] === "`") {
      const end = codeSpanEnd(text, index);
      if (end > 0) { output += text.slice(index, end); index = end; continue; }
    }
    if (text[index] === "[" || text[index] === "!") {
      const end = existingLinkEnd(text, index, referenceLabels, brackets, parentheses);
      if (end > 0) { output += text.slice(index, end); index = end; continue; }
    }
    if (text[index] === "<") {
      const end = text.indexOf(">", index + 1);
      if (end > index && !/[\r\n]/.test(text.slice(index, end))) {
        output += text.slice(index, end + 1);
        index = end + 1;
        continue;
      }
    }
    const scheme = text.slice(index, index + 8);
    let candidate = null;
    if (/^https?:\/\//i.test(scheme)) {
      let end = index;
      while (end < text.length && !/[\s<>"'`\\]/.test(text[end])) end += 1;
      candidate = text.slice(index, end);
    }
    const previous = index > 0 ? text[index - 1] : "";
    if (candidate && (!previous || !/[\p{L}\p{N}_]/u.test(previous))) {
      const url = trimURL(candidate);
      const authority = url.replace(/^https?:\/\//i, "").split(/[/?#]/)[0];
      if (authority && /[\p{L}\p{N}]/u.test(authority)) {
        output += "[" + markdownLabel(urlLabel(url)) + "](" +
          markdownDestination(url) + ")";
        index += url.length;
        continue;
      }
    }
    output += text[index++];
  }
  return {output};
}
