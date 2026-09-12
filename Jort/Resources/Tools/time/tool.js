export default async function(input) {
  return {output: input.clock.slice(11, 19) + "Z" + input.content};
}
