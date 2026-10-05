// Editable supported named entities. Semicolons are required.
// Decoding is a single pass: &amp;lt; becomes &lt;, never recursively <.
const NAMED_ENTITIES = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: "\u00a0",
  copy: "©", reg: "®", trade: "™", hellip: "…",
  ndash: "–", mdash: "—", lsquo: "‘", rsquo: "’", ldquo: "“", rdquo: "”"
};

function decodeEntity(entity, name) {
  if (Object.prototype.hasOwnProperty.call(NAMED_ENTITIES, name)) {
    return NAMED_ENTITIES[name];
  }
  if (!/^#(?:[0-9]+|[xX][0-9a-fA-F]+)$/.test(name)) return entity;
  const hexadecimal = /^#[xX]/.test(name);
  const scalar = parseInt(name.slice(hexadecimal ? 2 : 1), hexadecimal ? 16 : 10);
  // Reject NUL, surrogate code points, out-of-range values and noncharacters.
  if (!Number.isInteger(scalar) || scalar <= 0 || scalar > 0x10ffff ||
      (scalar >= 0xd800 && scalar <= 0xdfff) ||
      (scalar >= 0xfdd0 && scalar <= 0xfdef) || (scalar & 0xffff) >= 0xfffe) {
    return entity;
  }
  return String.fromCodePoint(scalar);
}

export default async function(input) {
  return {output: input.content.replace(
    /&([A-Za-z][A-Za-z0-9]*|#[0-9]+|#[xX][0-9a-fA-F]+);/g, decodeEntity)};
}
