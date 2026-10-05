// Include Unicode NEL (U+0085), which ECMAScript's \s omits, as well as BOM.
export default async function(input) {
  return {output: input.content.replace(/[\s\u0085]/g, "")};
}
