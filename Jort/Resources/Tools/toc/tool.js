// Edit indentation and bullet style to change the generated Markdown list.
// Links are portable Markdown fragments, not native Jort navigation.
const INDENT = "  ";
const BULLET = "-";

function headingText(markdown) {
  // Readable text from common inline decoration; no URL title fetches.
  return markdown
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/\[([^\]]+)\](?:\[[^\]]*\])/g, "$1")
    .replace(/<[^>]*>/g, "")
    .replace(/\\([\\`*_{}\[\]()#+.!>-])/g, "$1")
    .replace(/[`*_~]/g, "")
    .replace(/&(amp|lt|gt|quot|apos|nbsp);/g, (_, entity) =>
      ({amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " "})[entity])
    .trim();
}

function anchorFor(title, used) {
  const base = title.toLowerCase()
    .replace(/[^\p{L}\p{M}\p{N}_\s-]/gu, "")
    .trim().replace(/\s+/g, "-");
  // A global set handles collisions with headings already ending in "-1".
  let anchor = base;
  let suffix = 1;
  while (used.has(anchor)) anchor = base + "-" + suffix++;
  used.add(anchor);
  return anchor;
}

function markdownLabel(text) {
  return text.replace(/([\\[\]])/g, "\\$1");
}

function extractHeadings(content) {
  const headings = [];
  let fence = null;
  let paragraph = [];
  for (const line of content.split(/\r\n|\r|\n/)) {
    if (fence) {
      const closing = line.match(/^ {0,3}(`{3,}|~{3,})[ \t]*$/);
      if (closing && closing[1][0] === fence.character &&
          closing[1].length >= fence.length) fence = null;
      continue;
    }
    const opening = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    if (opening && !(opening[1][0] === "`" && opening[2].includes("`"))) {
      fence = {character: opening[1][0], length: opening[1].length};
      paragraph = [];
      continue;
    }
    // Indented code and container/reference lines do not become headings.
    if (/^(?: {4}|\t)/.test(line) ||
        /^ {0,3}(?:>|[-+*][ \t]+|\d+[.)][ \t]+|\[[^\]]+\]:)/.test(line)) {
      paragraph = [];
      continue;
    }
    const atx = line.match(/^ {0,3}(#{1,6})(?:[ \t]+(.*)|[ \t]*)$/);
    if (atx) {
      const text = (atx[2] ?? "").replace(/[ \t]+#+[ \t]*$/, "");
      headings.push({level: atx[1].length, title: headingText(text)});
      paragraph = [];
      continue;
    }
    const setext = line.match(/^ {0,3}(=+|-+)[ \t]*$/);
    if (setext && paragraph.length) {
      headings.push({
        level: setext[1][0] === "=" ? 1 : 2,
        title: headingText(paragraph.join(" "))
      });
      paragraph = [];
      continue;
    }
    // Blank lines and thematic breaks terminate candidate Setext paragraphs.
    if (!line.trim() || /^ {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$/.test(line)) {
      paragraph = [];
    } else {
      paragraph.push(line.trim());
    }
  }
  return headings;
}

export default async function(input) {
  const headings = extractHeadings(input.content);
  if (!headings.length) return {report: "No Markdown headings in this content block."};
  const usedAnchors = new Set();
  const ancestors = [];
  const lines = headings.map(heading => {
    while (ancestors.length && ancestors[ancestors.length - 1] >= heading.level) {
      ancestors.pop();
    }
    const depth = ancestors.length;
    ancestors.push(heading.level);
    const anchor = anchorFor(heading.title, usedAnchors);
    return INDENT.repeat(depth) + BULLET + " [" + markdownLabel(heading.title) +
      "](#" + anchor + ")";
  });
  return {output: lines.join("\n")};
}
