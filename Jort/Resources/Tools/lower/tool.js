// Unicode casing applies to raw text, including code and URL paths.
export default async function(input) {
  return {output: input.content.toLowerCase()};
}
