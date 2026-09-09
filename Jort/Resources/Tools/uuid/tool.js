export default async function(input) {
  if (input.content.trim()) return {error: "UUID does not accept content."};
  return {output: input.uuid};
}
