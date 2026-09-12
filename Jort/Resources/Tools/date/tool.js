export default async function(input) {
  return {output: input.clock.slice(0, 10) + input.content};
}
