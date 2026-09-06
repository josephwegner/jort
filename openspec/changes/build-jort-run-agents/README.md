# build-jort-run-agents

Add simple asynchronous agents with bounded context and safe insertion.

Implementation prerequisite: `establish-editor-ui-shell`, followed by Run history/search and tools. Agent UI consumes `LinePresentationLayout`: explanatory UI expands its anchor line, canonical output receives normal line numbers, and action controls expand their own anchor. Keep widget lifecycle/persistence in this feature; the shell's accessory descriptors are transient views only.
