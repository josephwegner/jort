// One replacement pass prevents generated ampersands from being re-escaped.
const ENTITIES = {"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"};

export default async function(input) {
  return {output: input.content.replace(/[&<>"']/g, character => ENTITIES[character])};
}
