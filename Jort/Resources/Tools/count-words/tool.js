// Captured-locale Unicode segmentation keeps contractions together and omits
// punctuation-only segments. Never substitute an ASCII split on whitespace.
export default async function(input) {
  const words = input.analysis?.words;
  if (!Number.isInteger(words) || words < 0) {
    return {error: "Captured Unicode word analysis is unavailable or invalid."};
  }
  return {report: "Words: " + words};
}
