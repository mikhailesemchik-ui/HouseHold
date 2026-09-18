# Household OS — Design Reference Package

Place this folder in the project as:

```text
HouseHold/
└─ docs/
   └─ design/
      ├─ household_os_design_board_v2.html
      ├─ household_os_ui_handoff_v2.md
      └─ README.md
```

These are reference files only. Do not add them to Flutter runtime assets, `lib/`, Android resources, or iOS resources.

## Recommended `CLAUDE.md` addition

Merge this section into the existing project `CLAUDE.md`:

```markdown
## UI/UX design source

For Household OS UI implementation, read:

- `docs/design/household_os_design_board_v2.html`
- `docs/design/household_os_ui_handoff_v2.md`

These are the approved visual/interaction references.

The HTML board is the visual reference.
The Markdown handoff is the implementation/behavior reference.

If they appear to conflict:
- preserve existing product/business semantics;
- follow the handoff for behavior and accessibility;
- follow the board for visual hierarchy and composition;
- never add backend fields, queries, metrics, or behavior solely to match illustrative mockup data.

Do not modify product/backend behavior merely to match illustrative mockup values.
```

Do not replace the existing `CLAUDE.md`; only merge the section above.
