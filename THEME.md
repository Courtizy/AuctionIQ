# AuctionIQ look

Every page of the addon follows these rules. A colour changes in `Theme.lua`.

## Style

- Flat dark panels with a 1px border, no Blizzard frame art (ElvUI style).
- Title bar in the panel colour with a 1px gold rule under it. The name is gold and the page name is grey.
- Money uses the game's gold, silver and copper coin icons, as TSM does. `/aiq coins` switches to `g s c` text.
- Profit is green, loss and warnings are red, and labels are gold.

## Two palettes, one window

AuctionIQ (every page but one) is navy, gold and emerald: analytical, decision-making. Its
Clearinghouse ledger tab is plum, parchment and gold: the books. Switching to the Clearinghouse tab
re-tints the window and its title reads "Clearinghouse". The Clearinghouse tab sits last, after AuctionIQ's own pages.

## With ElvUI and ToxiUI

When ElvUI is loaded, AuctionIQ keeps ElvUI's structure and tints it with the palette:

- Windows use ElvUI's `Transparent` template and title bars its `Default` template, with ElvUI's
  borders and backdrop alpha. ToxiUI hooks those templates, so its soft shadow, inner shadow and noise
  come along when its theme is on.
- Fonts are ElvUI's (ToxiUI's, if ToxiUI set them). Buttons and the close button use ElvUI's skins.
- The backdrop colour comes from the palette (navy or plum), so the two identities still read.
- `/aiq theme` switches to ElvUI's own colours instead: its value colour as the accent, its backdrop
  and border colours. Profit green, loss red and coin icons stay as they are.
- The minimap button turns square to match ElvUI's square minimap.

## Colours (dark)

| Token  | AuctionIQ | Clearinghouse | Used for |
|--------|-----------|---------------|----------|
| bg     | `#0e1729` navy | `#1c1222` plum | window background |
| panel  | `#15213b` | `#281a30` | title bar, buttons |
| line   | `#263a63` | `#45304f` | borders and rules |
| fg     | `#e6e8ee` | `#efe4c8` parchment | body text |
| muted  | `#9aa6bd` | `#b8a69a` | hints, page name, footer |
| accent | `#e0a83a` | `#e0a83a` | gold: name, headings, tooltip labels |
| iq     | `#34c77b` emerald | `#d8c39a` | the trend line in the icon, highlights |
| ok     | `#6cc58f` | `#6cc58f` | profit |
| bad    | `#ef7d72` | `#ef7d72` | loss, FULL Concentration |

## Voice

Plain words by default. A few places are in character, as a goblin clearing bank would put it:

- Footer: "All trades settled in gold."
- Idle Concentration: "Idle Concentration is gold left on the table."

Add new in-character lines only to headers, footers and warnings, never to numbers or instructions.
