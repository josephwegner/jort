export default async function(input) {
  const trailing = input.content.endsWith("\n");
  const lines = input.content.split("\n");
  if (trailing) lines.pop();
  lines.sort((a, b) => a < b ? -1 : a > b ? 1 : 0);
  return {output: lines.join("\n") + (trailing ? "\n" : "")};
}
