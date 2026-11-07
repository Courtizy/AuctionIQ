# Clearinghouse look

The addon and the companion page are one product, so they share these rules. A colour changes in
`Theme.lua` and in the page's CSS together.

## Style

- Flat dark panels with a 1px border, no Blizzard frame art (ElvUI style).
- Title bar in the panel colour with a 1px gold rule under it. The name is gold and the page name is grey.
- Money uses the game's gold, silver and copper coin icons, as TSM does. `/ch coins` switches to `g s c` text.
- Profit is green, loss and warnings are red, and labels are gold.

## With ElvUI and ToxiUI

When ElvUI is loaded, Clearinghouse uses it instead of its own look:

- Windows use ElvUI's `Transparent` template and title bars its `Default` template. ToxiUI hooks those
  templates, so its soft shadow, inner shadow and noise come along when its theme is on.
- Fonts are ElvUI's (ToxiUI's, if ToxiUI set them). Buttons and the close button use ElvUI's skins.
- The accent colour is ElvUI's value colour, and borders and backdrops are ElvUI's. Profit green,
  loss red and coin icons stay as they are.
- The minimap button turns square to match ElvUI's square minimap.

## Colours (dark)

| Token  | Hex       | Used for |
|--------|-----------|----------|
| bg     | `#141821` | window background |
| panel  | `#1b202b` | title bar, buttons |
| line   | `#2c3342` | borders and rules |
| fg     | `#e6e8ee` | body text |
| muted  | `#9aa2b3` | hints, page name, footer |
| accent | `#e0a83a` | Clearinghouse gold: name, headings, tooltip labels |
| ok     | `#6cc58f` | profit |
| bad    | `#ef7d72` | loss, FULL Concentration |

## Voice

Plain words by default. A few places are in character, as a goblin clearing bank would put it:

- Footer: "All trades settled in gold."
- Idle Concentration: "Idle Concentration is gold left on the table."

Add new in-character lines only to headers, footers and warnings, never to numbers or instructions.
