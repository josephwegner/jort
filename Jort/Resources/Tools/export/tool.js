// Suggestions are filenames, never paths. The native save panel owns the
// destination, extension choice, sanitization and overwrite confirmation.
const DEFAULT_FILENAME = "note.md";
// At most 60 Unicode code points fit the host's 256-byte UTF-8 filename bound.
const MAXIMUM_STEM_CHARACTERS = 60;

function suggestFilename(content) {
  const lines = content.split(/\r\n|\r|\n/);
  const heading = lines.find(line => /^ {0,3}#{1,6}[ \t]+\S/.test(line));
  const firstText = heading ?? lines.find(line => line.trim());
  if (!firstText) return DEFAULT_FILENAME;
  const stem = firstText
    .replace(/^ {0,3}#{1,6}[ \t]+/, "")
    .replace(/[ \t]+#+[ \t]*$/, "")
    .replace(/[<>:"/\\|?*\u0000-\u001f\u007f-\u009f]/g, "")
    .replace(/^[.\s]+|[.\s]+$/g, "");
  const shortened = Array.from(stem).slice(0, MAXIMUM_STEM_CHARACTERS).join("");
  return shortened ? shortened + ".md" : DEFAULT_FILENAME;
}

export default async function(input) {
  return {action: {
    kind: "file.export", content: input.content,
    filename: suggestFilename(input.content)
  }};
}
