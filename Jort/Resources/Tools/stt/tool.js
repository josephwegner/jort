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
  // Match only leading ASCII spaces on each logical line. Keep each separator.
  const output = input.content.split(/(\r\n|\r|\n)/).map((part, index) => {
    if (index % 2 === 1) return part;
    return part.replace(/^ +/, spaces =>
      "\t".repeat(Math.floor(spaces.length / width)) +
      " ".repeat(spaces.length % width));
  }).join("");
  return {output};
}
