export default async function(input) {
  if (input.content.trim()) return {error: "Date does not accept content."};
  return {output: input.clock.slice(0, 10)};
}
