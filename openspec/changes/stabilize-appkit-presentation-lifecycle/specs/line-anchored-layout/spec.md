## ADDED Requirements

### Requirement: Shared line geometry is prepared outside drawing
Jort SHALL prepare visible line bands, ruler labels and hit targets, accessories, invocation frames, and viewport anchors during explicit layout or viewport reconciliation and SHALL make ruler and accessory drawing read that committed geometry without mutation.

#### Scenario: Line layout becomes available
- **WHEN** TextKit reports visible fragments for the viewport plus bounded overscan
- **THEN** Jort builds and commits one shared immutable geometry snapshot before invalidating ruler or accessory display
- **AND** control hierarchy and frame updates occur outside every paint callback

#### Scenario: Ruler paint finds no current geometry
- **WHEN** the ruler is asked to draw before a matching geometry epoch has committed
- **THEN** it paints only safe committed/base ruler state
- **AND** does not force TextKit layout, enumerate the entire document, or call control reconciliation from drawing

#### Scenario: Accessory visibility changes
- **WHEN** an anchored accessory enters, leaves, expands within, or moves relative to the viewport
- **THEN** a coalesced layout invalidation prepares the new line bands and desired mount set
- **AND** one later reconciliation aligns text, gutter, hit targets, and controls without recursive layout
