// Edit the paragraph text or default count to customize generated filler.
const DEFAULT_PARAGRAPHS = 1;
const PARAGRAPH = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.";

export async function validate(input) {
  const count = input.arguments?.paragraphs ?? DEFAULT_PARAGRAPHS;
  return Number.isInteger(count) && count >= 1 && count <= 100
    ? {output: ""}
    : {error: "Paragraphs must be an integer from 1 to 100."};
}

export default async function(input) {
  const validation = await validate(input);
  if (validation.error) return validation;
  const count = input.arguments?.paragraphs ?? DEFAULT_PARAGRAPHS;
  return {output: Array(count).fill(PARAGRAPH).join("\n\n")};
}
