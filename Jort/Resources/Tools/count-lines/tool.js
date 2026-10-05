export default async function(input) {
  const lines = input.content ? input.content.split(/\r\n|\r|\n/) : [];
  // Empty input has no lines; one trailing separator does not add an item.
  if (/\r\n$|\r$|\n$/.test(input.content)) lines.pop();
  const nonEmpty = lines.filter(line => /[^\s\u0085]/.test(line)).length;
  return {report: "Lines: " + lines.length + "\nNon-empty lines: " + nonEmpty};
}
