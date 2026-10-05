// The host counts extended grapheme clusters, not code units or code points.
export default async function(input) {
  const analysis = input.analysis;
  if (!analysis || !Number.isInteger(analysis.characters) ||
      !Number.isInteger(analysis.charactersWithoutWhitespace) ||
      analysis.characters < 0 || analysis.charactersWithoutWhitespace < 0 ||
      analysis.charactersWithoutWhitespace > analysis.characters) {
    return {error: "Captured Unicode character analysis is unavailable or invalid."};
  }
  return {report:
    "Characters: " + analysis.characters +
    "\nWithout whitespace: " + analysis.charactersWithoutWhitespace};
}
