# Normative line identity contract

LineID denotes textual lineage, not an absolute line number or text-matching heuristic. A reference resolves only by UUID. Emoji is the primary user-facing landmark identity; duplicate emoji and emoji replacement do not change routing UUIDs.

| Operation | Required identity/timestamp result |
|---|---|
| Edit within a line, including replacement of all content without its terminator | Keep its ID and creation timestamp; advance lastEditedAt. |
| Insert complete lines at an existing line's start | New lines get new IDs; the original line and its anchor move with its text. |
| Split within a line | Leading fragment keeps the ID; trailing fragments get new IDs. |
| Join by removing a separator | Leading line keeps its ID; removed IDs detach. No automatic reassignment of their landmarks. |
| Delete whole lines including their terminators | Deleted IDs detach; an unchanged successor keeps its own ID. |
| Multiline replacement / replace-all | Boundary-surviving leading lineage can remain; replaced complete lines receive fresh IDs. No matching by text. |
| Cut then paste elsewhere | Deletion detaches old IDs; paste creates new lineage. Apparent movement is not inferred. |
| Empty/whitespace line | Structural ID remains while the line exists; both timestamps are nil. New visible content gets new timestamps. |
| Undo / redo | Restore exact text, line IDs, timestamps, and anchor metadata through a restore transaction; advance the live revision once. |
| IME | Marked text is provisional; the committed composition enters the same edit transaction path once. |
| Programmatic insertion | Resolve the explicit line UUID, reject a stale base revision, then use the same edit reconciliation. |
| Restore | Validate the full snapshot and same document UUID; restore identities exactly while assigning a new live revision. |
| Duplicate emoji / emoji change | Landmark UUID and line UUID remain the routing identity. No matching or retargeting by emoji. |

Detached landmarks retain their original line UUID in metadata. They do not resolve to a nearby line. Undo or a later explicit repair may resolve them; there is no implicit transfer. The current API exposes this as `snapshot.isDetached(landmark)`. The prototype is a domain/test fixture only; landmark UI remains deferred.

Every accepted transaction, including an explicit no-op metadata transaction, advances the revision exactly once. Stale or invalid transactions do not advance it. Committed revision records successful completion of the entire save operation, including the recovery snapshot; it is not a history checkpoint ID.
