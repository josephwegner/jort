export async function validate(input) {
  return typeof input.arguments?.separator === "string"
    ? {output: ""}
    : {error: "Supply a separator. Use an empty string to concatenate lines."};
}

export default async function(input) {
  const validation = await validate(input);
  if (validation.error) return validation;
  if (!input.content) return {output: ""};
  const lines = input.content.split(/\r\n|\r|\n/);
  // One terminal separator closes the last item; it does not create a new one.
  if (/\r\n$|\r$|\n$/.test(input.content)) lines.pop();
  return {output: lines.join(input.arguments.separator)};
}
