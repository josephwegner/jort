// Remove ambiguous characters. You can edit the alphabet and default length.
// Every symbol must be unique; 2–256 symbols keep byte rejection sampling valid.
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
const DEFAULT_LENGTH = 12;

export async function validate(input) {
  const length = input.arguments?.length ?? DEFAULT_LENGTH;
  const symbols = Array.from(ALPHABET);
  if (!Number.isInteger(length) || length < 1 || length > 4096) {
    return {error: "Length must be an integer from 1 to 4096."};
  }
  if (symbols.length < 2 || symbols.length > 256 ||
      new Set(symbols).size !== symbols.length) {
    return {error: "Use an alphabet with 2–256 unique characters."};
  }
  if (!Array.isArray(input.entropy) || input.entropy.length > 16384 ||
      input.entropy.some(byte => !Number.isInteger(byte) || byte < 0 || byte > 255)) {
    return {error: "Captured random bytes are unavailable or invalid."};
  }
  return {output: ""};
}

export default async function(input) {
  const validation = await validate(input);
  if (validation.error) return validation;
  const length = input.arguments?.length ?? DEFAULT_LENGTH;
  const symbols = Array.from(ALPHABET);
  // Accept a whole number of alphabet-sized groups. Reject the leftover tail
  // so every symbol has exactly the same probability (unlike bare byte % size).
  const acceptanceLimit = 256 - (256 % symbols.length);
  let output = "";
  let accepted = 0;
  for (const byte of input.entropy) {
    if (byte >= acceptanceLimit) continue;
    output += symbols[byte % symbols.length];
    accepted += 1;
    if (accepted === length) return {output};
  }
  return {error: "Not enough captured entropy. Submit again to capture fresh random bytes."};
}
