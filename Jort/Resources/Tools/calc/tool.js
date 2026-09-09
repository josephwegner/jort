// Grammar: sum -> product -> unary -> power -> primary.
// Power is right associative and binds more tightly than a leading unary sign.
export default async function(input) {
  const text = input.content;
  let position = 0, depth = 0, tokens = 0;
  function space() { while (" \t\r\n".includes(text[position]) && position < text.length) position++; }
  function take(character) { space(); if (text[position] !== character) return false; position++; if (++tokens > 4096) throw Error("Expression is too complex."); return true; }
  function finite(value) { if (!Number.isFinite(value)) throw Error("Result is not finite."); return value; }
  function primary() {
    if (++depth > 128) throw Error("Expression is too deeply nested.");
    let value;
    if (take("(")) { value = sum(); if (!take(")")) throw Error("Expected closing parenthesis."); }
    else {
      space(); const start = position; let digits = 0;
      while (text[position] >= "0" && text[position] <= "9") { position++; digits++; }
      if (text[position] === ".") { position++; while (text[position] >= "0" && text[position] <= "9") { position++; digits++; } }
      if (!digits || ++tokens > 4096) throw Error("Expected a decimal number.");
      value = finite(Number(text.slice(start, position)));
    }
    depth--; return value;
  }
  function power() { const left = primary(); return take("^") ? finite(left ** unary()) : left; }
  function unary() {
    if (++depth > 128) throw Error("Expression is too deeply nested.");
    const value = take("+") ? unary() : take("-") ? -unary() : power(); depth--; return value;
  }
  function product() {
    let value = unary();
    while (true) {
      if (take("*")) value = finite(value * unary());
      else if (take("/")) { const right = unary(); if (right === 0) throw Error("Division by zero."); value = finite(value / right); }
      else if (take("%")) { const right = unary(); if (right === 0) throw Error("Division by zero."); value = finite(value % right); }
      else return value;
    }
  }
  function sum() { let value = product(); while (true) { if (take("+")) value = finite(value + product()); else if (take("-")) value = finite(value - product()); else return value; } }
  try { const value = sum(); space(); if (position !== text.length) throw Error("Unexpected character."); return {output: String(value)}; }
  catch (error) { return {error: error.message}; }
}
