// The native adapter renders Markdown and publishes HTML/RTF/plain text.
// This script only requests the declared action; it has no clipboard access.
export default async function(input) {
  return {action: {kind: "clipboard.rich", content: input.content}};
}
