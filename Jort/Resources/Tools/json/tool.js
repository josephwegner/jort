// Change this default and the manifest's defaultValue together.
const DEFAULT_INDENT = 2;

// This recursive-descent formatter validates JSON without converting numbers
// into JavaScript Number values. It emits the original string/number tokens.
// Deliberate duplication keeps json and json-min independently editable.
const MAXIMUM_DEPTH = 128;

function formatJSON(source, indentWidth) {
  let position = 0;
  const indentation = depth => " ".repeat(indentWidth * depth);

  function fail(message) {
    const before = source.slice(0, position);
    const line = before.split(/\r\n|\r|\n/).length;
    const lastLine = before.split(/\r\n|\r|\n/).pop();
    throw new Error("JSON at line " + line + ", column " +
      (lastLine.length + 1) + ": " + message);
  }

  function skipWhitespace() {
    while (position < source.length && /[ \t\r\n]/.test(source[position])) position += 1;
  }

  function readString() {
    const start = position;
    position += 1; // Opening double quote.
    while (position < source.length) {
      const character = source[position++];
      if (character === '"') return source.slice(start, position);
      if (character.charCodeAt(0) < 0x20) fail("Control characters must be escaped.");
      if (character !== "\\") continue;
      const escape = source[position++];
      if (escape === "u") {
        const digits = source.slice(position, position + 4);
        if (!/^[0-9a-fA-F]{4}$/.test(digits)) fail("Expected four hexadecimal escape digits.");
        position += 4;
      } else if (!escape || !'"\\/bfnrt'.includes(escape)) {
        fail("Invalid string escape.");
      }
    }
    fail("Unclosed string.");
  }

  function readNumber() {
    const match = source.slice(position).match(
      /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/);
    if (!match) fail("Expected a JSON number.");
    position += match[0].length;
    // The parent parser checks delimiters. 01, 1., and 1e cannot sneak through.
    return match[0];
  }

  function container(open, close, depth, object) {
    position += 1;
    skipWhitespace();
    if (source[position] === close) {
      position += 1;
      return open + close;
    }
    const members = [];
    while (true) {
      let key = "";
      if (object) {
        if (source[position] !== '"') fail("Object keys must be double-quoted strings.");
        key = readString();
        skipWhitespace();
        if (source[position++] !== ":") fail("Expected a colon after the key.");
        key += indentWidth ? ": " : ":";
      }
      const value = readValue(depth + 1);
      members.push(key + value);
      skipWhitespace();
      const separator = source[position++];
      if (separator === close) break;
      if (separator !== ",") fail("Expected a comma or closing " + close + ".");
      skipWhitespace();
      if (source[position] === close) fail("Trailing commas are not valid JSON.");
    }
    if (!indentWidth) return open + members.join(",") + close;
    return open + "\n" + indentation(depth + 1) +
      members.join(",\n" + indentation(depth + 1)) + "\n" + indentation(depth) + close;
  }

  function readValue(depth) {
    if (depth > MAXIMUM_DEPTH) fail("Nesting exceeds " + MAXIMUM_DEPTH + " levels.");
    skipWhitespace();
    const character = source[position];
    if (character === '"') return readString();
    if (character === "{") return container("{", "}", depth, true);
    if (character === "[") return container("[", "]", depth, false);
    for (const literal of ["true", "false", "null"]) {
      if (source.startsWith(literal, position)) {
        position += literal.length;
        return literal;
      }
    }
    if (character === "-" || (character >= "0" && character <= "9")) return readNumber();
    fail("Expected a JSON value.");
  }

  const result = readValue(0);
  skipWhitespace();
  if (position !== source.length) fail("Unexpected text after a value.");
  return result;
}

function publicError(error) {
  const message = error instanceof Error ? error.message : "";
  return /^JSON at line [0-9]+, column [0-9]+: /.test(message)
    ? message : "Enter valid JSON.";
}

export async function validate(input) {
  const indent = input.arguments?.indent ?? DEFAULT_INDENT;
  if (!Number.isInteger(indent) || indent < 1 || indent > 8) {
    return {error: "Indentation must be an integer from 1 to 8."};
  }
  try {
    formatJSON(input.content, indent);
    return {output: ""};
  } catch (error) {
    return {error: publicError(error)};
  }
}

export default async function(input) {
  const indent = input.arguments?.indent ?? DEFAULT_INDENT;
  if (!Number.isInteger(indent) || indent < 1 || indent > 8) {
    return {error: "Indentation must be an integer from 1 to 8."};
  }
  try {
    return {output: formatJSON(input.content, indent)};
  } catch (error) {
    return {error: publicError(error)};
  }
}
