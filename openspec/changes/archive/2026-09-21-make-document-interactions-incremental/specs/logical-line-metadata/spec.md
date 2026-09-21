## ADDED Requirements

### Requirement: Logical-line indexing avoids global offset maintenance
Jort SHALL store logical-line order, UTF-16 lengths, stable identities, and metadata in an indexed representation whose global locations are derived from aggregate prefixes, and SHALL preserve all existing split, join, timestamp, landmark, newline, and final-structural-line behavior without shifting each trailing record after a localized edit.

#### Scenario: Early line changes length
- **WHEN** a localized edit changes the UTF-16 length of a line near the start of a large document
- **THEN** later lines resolve to their new correct absolute locations through index aggregates
- **AND** their identities, timestamps, records, and unchanged index subtrees are not rewritten solely because their global offsets moved

#### Scenario: Stable line ID is resolved
- **WHEN** navigation, a landmark, an invocation anchor, or restoration resolves a surviving line ID
- **THEN** Jort locates that line through the persistent ID index without scanning every logical line
- **AND** derives the exact current UTF-16 range from sequence aggregates

#### Scenario: Newline sequence crosses an internal chunk boundary
- **WHEN** LF, CRLF, CR, NEL, line separator, or paragraph separator content is inserted, removed, or divided at an index chunk edge
- **THEN** the resulting logical lines and final structural line match the complete Foundation-compatible reference split
- **AND** chunk boundaries do not become visible in identity or timestamp behavior
