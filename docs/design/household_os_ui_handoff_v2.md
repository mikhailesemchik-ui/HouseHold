# Household OS — Implementation Handoff (from Visual Concept v2)

> Note re data source: any provider- or model-referring value below (e.g. "provider's incomplete-task count", "existing member-count field") is a placeholder name for "whatever your current domain layer already exposes with this meaning." Do not create matching field/query names — wire to your real equivalents; do not add new queries, fields, or computed metrics to match this doc's example copy.

Source of truth for visual/interaction decisions: `Household OS Design Board v2.dc.html`. This doc translates it to Flutter/Material 3. It is NOT authoritative for data — wire every screen to whatever the current provider/domain layer already exposes; do not add fields, queries, or product behavior to match mockup copy. Where a mockup shows a value the app may not currently compute (e.g. "3 tasks due today"), use the nearest real metric (e.g. incomplete task count) instead.

## Design tokens

```text
Ground              #F7F5F0
Surface             #FFFFFF
Tonal surface       #F1EEE6   (chips, invite bg, insight bg, segmented-control track)
Ink (primary text)  #23261F
Ink secondary       #5C5F55
Ink tertiary        #8D8F83   (placeholder, meta, disabled)
Outline/divider     #E4E0D5
Primary             #3D7A5E
Primary pressed     #2E5F48
Balance tonal bg    #EEF3EE   (Expenses debt/settled balance block only)

Tasks accent        ink #A85D42   tint #F2E3DA
Shopping accent     ink #9C7B2E   tint #F4ECD6
Expenses accent     ink #4C6E85   tint #DFE7EA
Members accent      ink #7D5B78   tint #EDE0EA
Statistics accent   ink #2F6B52   tint #DCE8E0
```

Radius scale: 8 (icon chips) · 10–12 (buttons, Level A/C actions, small controls) · 14–16 (banners, insight card) · 18 (tiles) · 20–22 (avatar chips, composer capsule).

Spacing scale: 4/8/12/14/16/20/24. Screen horizontal padding 20. Inter-section vertical rhythm 22–26. Row vertical padding 11–14.

Typography roles (system sans; use `Theme.of(context).textTheme` variants mapped as below, weights via `FontWeight`):
- Screen/page title: 20–26, w800
- Tile hero number: 28, w800
- Stat hero number: 44, w800
- Expense-form amount: ~52, w800
- Debt amount: 34, w800
- Body/list item: 15, w400–600
- Meta/secondary line: 12–13, w500–600, ink secondary/tertiary
- Eyebrow label (uppercase, tracked): 11–12, w700, ink tertiary, letterSpacing ~0.5
- Button label: 14–15, w700

Numeric/tabular: every money value and count uses `FontFeature.tabularFigures()` in the `TextStyle.fontFeatures`. Currency formatting via existing app formatter (integer cents → display string) — do not reformat amounts client-side ad hoc.

Fonts: system default only (`Theme.of(context).textTheme` / platform default). No font package dependency. Monospace (public IDs, invite codes) uses the platform monospace fallback (`fontFamily: 'monospace'` / `Roboto Mono` where already bundled) — do not add a font package for this.

---

## Global creation system (Level A/B/C)

- **Level A — primary creation** (New home, Add task, Add expense): `FilledButton.icon` or `FloatingActionButton.extended` — rounded rectangle, radius 12 (not a full pill), filled `primary`, white label, leading `+`/icon. Anchor per-screen (bottom-right extended FAB on Homes; page action elsewhere) — position varies, shape/color family does not.
- **Level B — fast creation** (Add shopping item): inline capsule `TextField` (radius 22, filled translucent surface, no visible border) + circular filled-primary trailing icon button. Only surface in the app besides bottom nav that uses the glass/translucent treatment.
- **Level C — secondary management** (Record settlement, Invite member): `OutlinedButton` or `TextButton`, radius 10–12, primary-colored label, no fill.

Never collapse these into one shared button widget — vary only the family, not the hierarchy.

---

## Bottom navigation (glass functional layer)

Custom bottom bar, not a bare `NavigationBar`, to get the translucency:

```dart
ClipRect(
  child: BackdropFilter(
    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
    child: Container(
      color: ground.withOpacity(0.72),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: Colors.white.withOpacity(0.6)))),
      child: NavigationBar(...) // or a Row of custom tab items
    ),
  ),
)
```

Height ~78 + safe-area bottom inset. Active tab: primary, bold label. Inactive: ink tertiary. This is the ONLY navigation-level glass; do not extend BackdropFilter to any content surface (tiles, list rows, cards, statistics, members).

---

## Household Dashboard

1. **Layout**: `CustomScrollView`/`ListView`: header → 2-up Tasks/Shopping row → 2-up Expenses/Members row → full-width Statistics row → Recent activity list → Invite block.
2. **Hierarchy**: Tasks/Shopping carry the heaviest visual weight (hero number + label); Expenses/Members are quieter (icon + label + one status line, no hero number); Statistics is a single full-width entry row, not a tile.
3. **Spacing**: 20 horizontal margin; 12 gap between grid tiles; 22–26 between sections.
4. **Typography**: household name 22/800; tile hero number 28/800; tile label 14/700; tile sub-label 12/regular ink tertiary; section eyebrows ("Recent activity", "Invite") 12/700 uppercase ink tertiary.
5. **Surface**: tiles are solid white `Material`/`Card`-equivalent, radius 18, no border, no shadow (or a hairline-only elevation). Screen background is `ground`.
6. **Radius**: 18 tiles, 16 statistics row, 8 icon chips, 14 invite pill.
7. **Feature accent**: icon-chip background tint + icon color only. **Do not** add a colored top border/stripe — that was removed in v2. Differentiation comes from hierarchy (hero number vs. status line), not decoration.
8. No primary/secondary action pair lives on the Dashboard itself; each sub-screen owns its own actions.
9. **Scroll**: whole page scrolls; tiles/rows never scroll independently.
10. Standard bottom nav, "Homes" tab active.
11. N/A (no text entry on this screen).
12. **Empty state**: if a household genuinely has 0 tasks/items, the tile shows "0" + label plainly — do not hide the tile or add illustration.
13. **Large text**: tiles must size to content (`Column`/`Wrap`, never a fixed-height `GridView` with forced aspect ratio) so a bigger hero number or wrapped label doesn't clip.
14. **Accessibility**: tile is a single tap target (`InkWell`/`Material` wrapping the whole tile), min 44×44 effective; icon-only elements need semantic labels.
15. **Must stay dynamic**: tile height, activity-row text (task/item names can be long), invite-code container width.
16. **Reference vs. strict**: exact copy ("4 members", "Settled up") is illustrative; use your real aggregate fields. The layout/hierarchy is strict.

---

## Shopping

1. **Layout**: `ListView` of item rows (no cards) + a floating composer + bottom nav, both docked outside the scroll area.
2. **Hierarchy**: active items first, plain; a muted "Completed · N" eyebrow, then completed rows (reduced opacity, strikethrough); composer always reachable above nav.
3. **Spacing**: row vertical padding 13; 14 gap between checkbox and text; composer sits 12–16 above the nav bar with 16 side margins.
4. **Typography**: item text 15/regular; completed text 15/regular w/ `TextDecoration.lineThrough` + ink tertiary; "Completed · N" 11.5/700 uppercase.
5. **Surface**: rows are bare (no `Card`), separated by a hairline `Divider` (outline color, 1px). Composer is the one translucent surface: white ~88% opacity + blur.
6. **Radius**: composer capsule 22; circular checkbox 11 (i.e., a circle, not Material's square `Checkbox` — implement as a custom `GestureDetector` + `AnimatedContainer` circle, or `Checkbox` with `shape: CircleBorder()`).
7. **Feature accent**: none needed on this screen — Shopping's identity is the composer + lightness, not color.
8. **Actions**: Level B composer is the only action; row-level overflow (rename/delete) appears as a trailing icon button, always present but low-contrast (ink tertiary) — not a decorative reveal-on-hover, since touch has no hover.
9. **Scroll**: list scrolls; composer and nav are fixed.
10. **Bottom-nav relationship — resting**: composer floats ~12–16px above the nav bar, its own surface, never merged with nav chrome.
11. **Keyboard behavior**: on composer focus, let `Scaffold(resizeToAvoidBottomInset: true)` push the composer up above the keyboard naturally (simplest, robust for any keyboard height) rather than hand-calculating an offset. The list must remain visible/scrollable behind it. The bottom nav may be visually de-emphasized/hidden while the keyboard is open (common pattern) since the composer is now the focus.
12. **Empty state**: centered quiet text ("Nothing on the list. Add the first item below.") + composer still visible/reachable — no illustration.
13. **Large text**: rows must wrap long item names to a second line without breaking row height (`Expanded(Text(..., softWrap:true))`); composer input must grow to 2 lines if needed (`TextField` with `minLines:1, maxLines:3`).
14. **Accessibility**: checkbox target ≥44×44 including padding even though the visual circle is 22px — pad the tap area, not the visual.
15. **Must stay dynamic**: row height (name length, text scale), composer height (keyboard, text scale).
16. Copy/item names are illustrative; checkbox shape, composer treatment, and list lightness are strict.

---

## Expenses — settled state

1. **Layout**: header → lightweight balance line → primary/secondary action row → history (or empty state).
2. **Hierarchy** (refined in v2): balance status is now a quiet inline row (check icon + "Everyone's settled up"), NOT a large tonal card — it should read as calm, not as a status panel competing with the rest of the page.
3. **Spacing**: balance block 6px top padding, 18 bottom padding, hairline divider below it; action row 20 top padding, 16 gap between the two actions.
4. **Typography**: "Household balance" eyebrow 11.5/700 ink tertiary; status line 17/700 ink primary.
5. **Surface**: no card/fill behind the balance line — it sits directly on `ground`, separated only by a 1px divider.
6. **Radius**: N/A for the balance row; 12 for the Add-expense button.
7. **Feature accent**: none on the settled message itself (a green checkmark glyph only, matching primary, not a full accent treatment).
8. **Actions**: primary `FilledButton.icon` "Add expense" (radius 12) fills available width or leads; secondary "Record settlement" as `TextButton`, clearly smaller, no fill — never two FABs.
9. **Scroll**: whole page scrolls; balance/action block scrolls with content (not pinned).
10. Standard bottom nav.
11. N/A.
12. **Empty history**: centered quiet text, no illustration, no border box.
13. **Large text**: status line wraps to 2 lines gracefully if needed; action row buttons should use `Wrap`/`Flexible` so long locale strings don't overflow.
14. **Accessibility**: check-icon + text must be one semantic label ("Everyone is settled up"), not read as two separate elements.
15. **Must stay dynamic**: balance block height, history list length.
16. Exact balance copy is illustrative (wire to the real balance/settlement computation); the *lightness* of the settled treatment vs. the debt treatment is strict — settled must look calmer than debt.

---

## Expenses — debt state

1. **Layout**: header → prominent balance block (avatars + relationship + amount) → same action row as settled → merged history list.
2. **Hierarchy**: this block is intentionally heavier than settled (tonal background `#EEF3EE`, radius 16–20) because a debt deserves attention — that contrast between the two states is deliberate and must be preserved.
3. **Spacing**: block padding ~22×20; 8–10 gap between avatar row and relationship text; 2–4 gap before the big amount.
4. **Typography**: relationship line ("Miguel owes Anna") 15–16/regular with names bold; amount 34/800 tabular.
5. **Surface**: tonal filled block (`#EEF3EE`), radius 16–20, no border/shadow.
6. **Radius**: 16–20 balance block; 14 avatar chips; 12 action button.
7. **Feature accent**: small avatar chips use each person's member-accent tint (reuse Members palette or per-user color, not a fixed pair) with an arrow glyph between them in `primary`-adjacent tone.
8. **Actions**: identical primary/secondary pattern as settled.
9. **History list**: one merged, chronological `ListView` — expense rows and settlement rows share row structure but differ by **leading icon shape/color + trailing text**, never color alone: expense = receipt icon (Expenses accent tint), plain bold amount; settlement = exchange-arrows icon (Statistics/primary-adjacent tint), amount styled muted with a small "Settled" caption underneath. Optional date-group headers ("This week") as plain eyebrow text, not sticky unless the list is long.
10. Standard bottom nav.
11. N/A.
12. Not applicable (debt implies at least one expense exists).
13. **Large text**: relationship line must wrap ("Miguel owes Anna" → two lines if names are long) without breaking the amount below it; avoid a single fixed-width Row that could clip.
14. **Accessibility**: amount + relationship should combine into one semantic announcement ("Miguel owes Anna 24 euros 50"); history rows need a full-row semantic label (who/what/amount), not per-fragment.
15. **Must stay dynamic**: balance block height (name length), history row height (title/participant-list length).
16. Names/amounts are illustrative; the two-tier visual weight (debt heavy, settled light) and the icon+text (not color-only) differentiation between expense/settlement rows are strict.

---

## Expense — full-screen form

1. **Layout**: full-screen route (`Navigator.push`, not an `AlertDialog`) — `AppBar`(close ✕, title, primary text action "Add") + scrollable body: amount hero → title field → paid-by chips → split rows → helper caption.
2. **Hierarchy**: amount is the dominant element (largest type on the whole screen); everything below is supporting detail.
3. **Spacing**: amount block ~32 top padding; each field group separated by dividers or 18–20 vertical gaps; chip rows use 10 gap and must `Wrap`.
4. **Typography**: amount ~52/800 tabular, currency symbol smaller (~26/700) and ink tertiary; field labels 11/700 uppercase ink tertiary; field values 16/600; participant name 15/regular; per-person share 14/regular tabular.
5. **Surface**: borderless full-bleed page on `ground`; the amount and title fields are borderless/underline style, not boxed Material `TextField` outlines.
6. **Radius**: 20 avatar chips, 10 split-row checkbox.
7. **Feature accent**: none needed — this is a neutral utility form.
8. **Actions**: single primary action in the `AppBar` (text button "Add", `primary` color, disabled/ink-tertiary until valid) — no separate FAB, no bottom sticky button duplicating it.
9. **Scroll**: `SingleChildScrollView`; must not clip under keyboard.
10. No bottom nav on this screen (it's a modal-equivalent full-screen route).
11. **Keyboard behavior**: `Scaffold(resizeToAvoidBottomInset: true)` (default) so the field in focus stays visible; test with the Title field focused and the amount hero already filled — the hero must not get pushed fully offscreen (keep it compact enough, or let it scroll normally with the field).
12. N/A (form always has default state, e.g. current user pre-selected as payer).
13. **Large text**: paid-by chips and split rows must `Wrap`, not `Row` with fixed children — verified against 4+ participants and a long name ("Christina Okafor") in the v2 board.
14. **Accessibility**: amount field needs a numeric keyboard (`TextInputType.numberWithOptions(decimal: true)`) and a clear "Amount" semantic label distinct from its large visual size; split-row checkboxes need per-person semantic labels including the computed share.
15. **Must stay dynamic**: split-row count and chip-row height (participant count varies 1–8+ per household).
16. **Strict**: equal-split only, no custom per-person amounts, no currency selector — do not add either even though a real ledger app might have them; Household OS's domain model is equal-split only. If the product later adds custom splits, that is a product decision, not something to infer from this doc.

---

## Statistics

1. **Layout**: header → compact period selector → primary metric hero → member distribution → recurring-task list → rotation-suggestion card.
2. **Hierarchy**: one dominant number (completed tasks for the selected period), everything else is secondary/supporting detail. No pie charts, gauges, or score rings.
3. **Spacing**: 18 top padding to selector; 26 before the hero number; 22–24 between subsequent sections.
4. **Typography**: hero number 44/800 tabular; section labels 13/700 ink secondary; bar row name 13.5/600, value 13.5/regular tabular ink tertiary.
5. **Surface**: page is bare `ground`; only the rotation-suggestion card and the period-selector track use a tonal fill (`#F1EEE6`).
6. **Radius**: 12 selector track/segments, 16 insight card.
7. **Feature accent**: Statistics accent (`#2F6B52`/`#DCE8E0`) only on its own icon chip elsewhere (e.g. Dashboard entry row); within this screen, bars/progress use `primary` directly.
8. **Period selector**: `SegmentedButton<Period>` (Material 3 native) styled compact — not the oversized pill-row from v1.
9. **Distribution bars**: `Row` (name, value) + `ClipRRect(borderRadius: 4, child: LinearProgressIndicator(value: fraction, color: primary, backgroundColor: tonal))`.
10. Standard bottom nav.
11. N/A.
12. **Empty state**: if there's not enough data, replace the relevant section (bars/patterns) with quiet explanatory text ("Not enough activity yet to show a pattern") — never a fairness score or blank chart.
13. **Large text**: bar rows must let the value text wrap/shrink before the bar itself collapses; insight card text reflows normally.
14. **Accessibility**: bars need a text equivalent (already shown as "N tasks · X%" alongside, not bar-only); segmented control keeps 44px min touch targets per segment.
15. **Must stay dynamic**: number of member-distribution rows (household size varies), recurring-task list length.
16. Period values, metric numbers are illustrative; the *no-gamification* rule (no fairness score, no rankings, no red/warning treatment) is strict product policy, not a style choice.

### Rotation suggestion (detail)

- Card: tonal (`#F1EEE6`), radius 16, padding 16.
- Row 1: icon chip (leaf/rotate glyph, Statistics tint) + text column: "Pattern noticed" (13.5/700) → factual observation sentence (13/regular, ink secondary, strictly descriptive: "X has completed 'Y' N of the last M times.") → "Suggested next assignment" eyebrow (11.5/700 ink tertiary) → suggested person name (14/700).
- Row 2 (indented under the text column, `Wrap` with 16 gap): **Apply suggestion** — `FilledButton.tonal` or small `FilledButton`, radius 10, primary fill, the one emphasized action here. **Adjust manually** — `TextButton`, primary-colored, opens the normal assignee picker. **Keep current** — `TextButton`, ink-tertiary colored, dismisses the suggestion without acting.
- Tone rule (strict): never red/warning color, never a percentage framed as a "fairness score," never second-person accusatory phrasing ("You're not doing your share"). Always third-person factual observation + neutral suggestion.

---

## Members

1. **Layout**: `ListView.separated` (hairline dividers) of member rows + footer secondary action.
2. **Hierarchy**: identity (avatar + name) is primary; role/management is secondary and never visually loud.
3. **Spacing**: row padding 13 vertical / 20 horizontal (or 0 if the `ListView` itself has horizontal padding); 14 gap between avatar and text block.
4. **Typography**: name 15/700; "You" tag 10.5/700 in a small tonal pill; "Owner" label 12.5/600 ink tertiary (plain text, not a heavy badge).
5. **Surface**: bare rows, hairline dividers, no card wrapping.
6. **Radius**: avatar 20 (full circle), "You" tag 6.
7. **Feature accent**: avatar background uses a per-member tint (rotate through the muted accent tint set, or a real per-user color if the product already assigns one) with the initial in the matching ink color.
8. **Actions**: management (remove/change role/transfer ownership) lives behind a trailing overflow `IconButton` on rows the current user (if owner) can manage — never inline buttons per row. Footer "Invite member" is Level C (`OutlinedButton`).
9. **Scroll**: whole list scrolls; footer action scrolls with it (not pinned) unless the household regularly has enough members to warrant a persistent footer — start with in-flow.
10. Standard bottom nav.
11. N/A.
12. **1-member household**: single row + footer action; do not add filler content or illustration for the sparse case — it's correct as-is.
13. **Large text**: name + tags must wrap onto a second line if needed without pushing the avatar or trailing icon off-row (`Expanded` around the text column).
14. **Accessibility**: "You" and "Owner" must be included in the row's semantic label, not conveyed by color/shape alone.
15. **Must stay dynamic**: row height (name length — verified against a long name, "Christina Okafor", in the v2 board), list length (1 to 6+ members).
16. **Strict (v2 refinement)**: public ID is shown for the current user's own row only (where it's already useful, e.g. to share); other members' public IDs move to a details/overflow surface, not the main scanning list. This is a privacy/scannability rule, not just a style preference.

---

## Today

1. **Layout**: title + date header → sectioned list (Overdue / Today / Upcoming / Anytime), sections rendered only if non-empty.
2. **Hierarchy**: task title first, then a single quiet meta line combining household + schedule info — restored in v2 after v1 over-simplified this to a household-only badge.
3. **Spacing**: 24 before each section eyebrow, 11 row padding.
4. **Typography**: "Today" title 26/800; date 13/regular ink tertiary; section eyebrow 12/700 (Overdue in Tasks-accent ink, others in ink secondary); task title 15/regular; meta line 12/regular ink tertiary.
5. **Surface**: bare rows, hairline dividers, no chips/badges around the household name.
6. **Radius**: circular checkbox 11 (same custom shape as Shopping).
7. **Feature accent**: only the "Overdue" eyebrow label borrows the Tasks accent ink color; household attribution itself stays plain ink-tertiary text, not a colored tag.
8. **Meta-line composition** (strict order): task title (+ small recurrence glyph if the task recurs) → meta line = `Household · time` when a due time exists (e.g. "Home 1 · 18:00"), or `Household · frequency` when useful (e.g. "· Daily"), or just `Household` for Anytime tasks (no fabricated time).
9. **Scroll**: whole page scrolls.
10. Standard bottom nav, "Today" tab active.
11. N/A.
12. **Empty state**: if no tasks anywhere, a single quiet centered message — no per-section empty placeholders.
13. **Large text**: title + meta line must each wrap independently without the recurrence glyph or checkbox shifting.
14. **Accessibility**: recurrence glyph needs a semantic label ("repeats daily"), not icon-only meaning.
15. **Must stay dynamic**: number of sections shown (only non-empty ones), row count per section.
16. Multi-household attribution text and exact times are illustrative; the ordering (title → recurrence → household → schedule) is strict and must not regress back to household-badge-only.

---

## Homes

1. **Layout**: title + secondary icon action (invite) → `ListView` of household rows → Level A extended action.
2. **Hierarchy**: each household is a destination row, not a decorative card.
3. **Spacing**: 14 row padding, 14 gap icon-to-text.
4. **Typography**: household name 16/700; meta line 12.5/regular ink tertiary.
5. **Surface**: bare rows with hairline dividers (or a very subtle `Material` tap ripple only) — no elevated cards.
6. **Radius**: icon chip 11, "New home" action 12.
7. **Feature accent**: icon chip uses a rotating/neutral tint per household or the primary tint — not meaningful per-household branding beyond that.
8. **Actions**: "New home" is Level A — `FloatingActionButton.extended` or `FilledButton.icon`, radius 12, bottom-anchored.
9. **Scroll**: list scrolls; FAB stays anchored (standard Scaffold FAB behavior).
10. Standard bottom nav, "Homes" tab active.
11. N/A.
12. **Empty state**: if the user has zero households (first run), replace the list with a short explanatory line + the same "New home" action — do not fabricate a sample household.
13. **Large text**: row text wraps normally; meta line uses only real counts the household model exposes (e.g. member count, task count) — never a fabricated "due" count if the model doesn't track due-ness there.
14. **Accessibility**: each row is one tap target with a combined semantic label (name + meta).
15. **Must stay dynamic**: row height, list length (including the 1-household case).
16. Meta copy ("4 members · 3 tasks due") is illustrative; use whichever real fields the Homes list query already returns (e.g. member count + total/incomplete task count) rather than adding a due-today computation.

---

## Non-goals for this pass (do not do)

- Do not add a fairness score, ranking, or red/warning styling anywhere in Statistics.
- Do not add custom expense splitting or currency selection to the form.
- Do not surface other members' public IDs on the main Members list.
- Do not invent a "tasks due today" (or similar) metric if the current provider doesn't compute it — use the nearest real aggregate.
- Do not expand `BackdropFilter`/glass beyond bottom nav + Shopping composer.
- Do not introduce a font package, animation package, or custom painter-heavy component library.
- Do not build a shared generic "action button" component that erases the Level A/B/C distinction.
