# AuctionIQ look

Every page of the addon follows these rules. A colour changes in `Theme.lua`.

## Style

Matched to ToxiUI's Dark style, read from its own files (ElvUI_ToxiUI 7.6): ElvUI backdrop `#1a1a1a`,
see-through backdrop `#292929` at 80%, black borders, a 4px soft shadow at 60%, the class colour as
ElvUI's value colour, ToxiUI's font for text and Montserrat Black for titles.

- Graphite panels with a black 1px border, no Blizzard frame art (ElvUI style).
- Title bar in the panel colour with a 2px accent rule under it. The brand stands alone, with no
  icon: AUCTIONIQ in Montserrat Black, IQ in the theme colour, then the window's name in grey.
  Chat messages start with the same brand.
- The theme colour follows ToxiUI's (ElvUI's value colour, which ToxiUI sets to the class colour, so
  it changes as you swap characters), or ElvUI's value colour without ToxiUI. With neither it is
  AuctionIQ blue `#3fc7eb`. If the colour changes while you play, the windows follow it.
- The active tab has the accent text and a 2px accent line.
- Progress bars (the advisor's recovery chance, the footer's Concentration bars) use ToxiUI's class
  gradient from its own settings, a shade of ElvUI's value colour into it, or AuctionIQ blue's
  gradient `#0080d7` to `#00d8ff`. Action buttons stay solid.
- Money uses the game's gold, silver and copper coin icons, as TSM does. `/aiq coins` switches to `g s c` text.
  Break-even prices are gold (`#e0a83a`).
- Profit is green, loss and warnings are red. Numbers in tables are right-aligned.
- The advisor opens with a Next Move block: the craft and how many, expected output if Multicraft
  applies, then profit per craft, break-even per item and the chance to recover the spend in 7 days.

## Two palettes, one window

AuctionIQ (every page but one) is ToxiUI graphite with the class accent. The earlier navy look is
kept in `Theme.lua` as `navy`. Its
Accounting tab is plum, parchment and gold: the books. Switching to Accounting re-tints the window;
the title still reads AuctionIQ. Accounting sits last, after the other tabs.

## With ElvUI and ToxiUI

When ElvUI is loaded, AuctionIQ keeps ElvUI's structure and tints it with the palette:

- Windows use ElvUI's `Transparent` template and title bars its `Default` template, with ElvUI's
  borders and backdrop alpha. ToxiUI hooks those templates, so its soft shadow, inner shadow and noise
  come along when its theme is on.
- Fonts are ElvUI's (ToxiUI's, if ToxiUI set them). Buttons and the close button use ElvUI's skins.
- The backdrop colour comes from the palette (graphite or plum), so the two identities still read.
- `/aiq theme` switches to ElvUI's own colours instead: its value colour as the accent, its backdrop
  and border colours. Profit green, loss red and coin icons stay as they are.
- The minimap button turns square to match ElvUI's square minimap.

## Colours (dark)

| Token  | AuctionIQ | Accounting | Used for |
|--------|-----------|---------------|----------|
| bg     | `#292929` at 80% | `#1c1222` plum | window background |
| panel  | `#1a1a1a` | `#281a30` | title bar, buttons, Next Move |
| line   | `#000000` | `#45304f` | borders |
| fg     | `#f2f2f2` | `#efe4c8` parchment | body text |
| muted  | `#a3a3ab` | `#b8a69a` | hints, page name, footer |
| accent | theme colour, default `#3fc7eb` | `#e0a83a` | wordmark IQ, headings, active tab, selection |
| gold   | `#e0a83a` | `#e0a83a` | break-even prices |
| iq     | `#34c77b` emerald | `#d8c39a` | the trend line in the icon, highlights |
| ok     | `#6cc58f` | `#6cc58f` | profit |
| bad    | `#ef7d72` | `#ef7d72` | loss, FULL Concentration |

## Voice

Plain words by default. A few places are in character, as a goblin clearing bank would put it:

- Footer: "All trades settled in gold."
- Idle Concentration: "Idle Concentration is gold left on the table."

Add new in-character lines only to headers, footers and warnings, never to numbers or instructions.
