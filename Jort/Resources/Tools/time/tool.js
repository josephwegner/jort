export default async function(input) {
  if (input.content.trim()) return {error: "Time does not accept content."};
  return {output: input.clock.slice(11, 19) + "Z"};
}
