// Set the manifest's defaultValue as well if you change this default.
const DEFAULT_WIDTH = 4;

export async function validate(input) {
  const width = input.arguments?.width ?? DEFAULT_WIDTH;
  return Number.isInteger(width) && width >= 1 && width <= 16
    ? {output: ""}
    : {error: "Spaces per tab must be an integer from 1 to 16."};
}

export default async function(input) {
  const validation = await validate(input);
  if (validation.error) return validation;
  const width = input.arguments?.width ?? DEFAULT_WIDTH;
  return {output: input.content.replace(/\t/g, " ".repeat(width))};
}
