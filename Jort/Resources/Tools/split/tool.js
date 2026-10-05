// A delimiter is literal text, not a regular expression. Do not trim segments.
export async function validate(input) {
  const delimiter = input.arguments?.delimiter;
  return typeof delimiter === "string" && delimiter.length > 0
    ? {output: ""}
    : {error: "Enter a non-empty literal delimiter."};
}

export default async function(input) {
  const validation = await validate(input);
  if (validation.error) return validation;
  return {output: input.content.split(input.arguments.delimiter).join("\n")};
}
