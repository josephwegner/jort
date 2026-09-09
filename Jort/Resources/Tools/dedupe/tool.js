export default async function(input) {
  const trailing = input.content.endsWith("\n");
  const lines = input.content.split("\n");
  if (trailing) lines.pop();
  return {output: Array.from(new Set(lines)).join("\n") + (trailing ? "\n" : "")};
}
