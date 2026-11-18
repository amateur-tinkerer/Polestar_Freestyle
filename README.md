# Polestar Free Questing

Polestar's guide window, arrow and map, but for the quests **already in your quest log**.

Each quest you have gets a step that says what to kill, collect, use or talk to. The step is placed where
Polestar's quest database has those mobs, drops and objects, with the nearby camps as spawn areas. Each
quest then gets a hand-in step at the NPC who takes it. Steps follow a nearest-first walk from where you
stand, and a hand-in always comes after that quest's work. Hand-ins to the same NPC in a row are merged into
one stop.

The guide updates as you play. When you accept, finish, hand in or abandon a quest, or move to another zone,
the steps are rebuilt in place. Your current step, ticks and skips are kept.

## Install

1. Download the newest `Polestar_FreeQuest-vX.Y.Z.zip` from this project's **Releases** page (on the right of
   the GitHub page). Unzip it into `World of Warcraft/_forever_/Interface/AddOns/`, so the `Polestar_FreeQuest`
   folder sits next to `Polestar`. To update, unzip the new release over the old folder.
2. You need Polestar 0.4.0 or newer, with the quest database on. It loads whenever any quest marker or quest
   tooltip is enabled under Options > Questing.

## Use

| Command | What it does |
|---|---|
| `/polestar free` | Opens free questing in its own tab. Your leveling guide's tab stays. |
| `/polestar free wetlands` | One zone's quests, wherever you are. A part of the name also works: `/polestar free dusk`. |
| `/polestar free all` | Every quest in your log, whatever the zone. |
| `/polestar free zone` | Back to following the zone you are in. |
| `/polestar free refresh` | Plans again now. |
| `/polestar free close` | Closes its tab. |

`/freequest` takes the same words. You can also open it from the guide menu, under Community guides >
Free questing.

**Choosing the zone in the window:** while free questing is the open tab, the guide window's `…` menu
starts with **Questing zone: Wetlands ›**. It opens a list with these choices:

- **Follow my zone**
- **All quests**
- Every zone in your quest log, with how many of your quests are there. The current choice is ticked.

**Zone scope** takes a quest when any of these is true:

- It sits under this zone's header in your quest log.
- Some of its open work is on this zone's map.
- It is ready to hand in to someone on this map.

When you pass through a zone where you have no quests, the guide keeps the last zone that had some. This
covers trips such as flying to Stormwind to hand in quests. A zone you chose yourself stays the guide's
wherever you go, until you choose another zone or Follow my zone.

## Quest browser

Open it with `/polestar quests` or `/freequest browse`. It is a **Quests** section in Polestar's hub, on the
rail beside Lookup and Dungeons.

- **Zones:** each zone shows its level range, for example `Westfall (10-20)`. Open a zone to see its quest
  chains and single quests. Open a chain to see its quests in order, prerequisites first.
- **Each quest shows:**
  - its level, coloured by how hard it is for you
  - its state: done, in your log, open, or locked (by level, or by an earlier quest)
  - the XP it gives you now, after Forever's cut for quests well below your level
  - its reward items; hover one for the item's tooltip
- **Sidebar filters:**
  - **In your quest log**
  - **Available** (the default): the quests open to you now. Your current zone is pinned first and
    opened. It reaches as far above your level as Polestar's own **Quests above your level** setting,
    whose slider sits on the page with **Low-level quests**. These are the same settings as Polestar's
    quest markers on the map, so changing one place changes the other.
  - **Marked**
  - **All quests**
- **Open and closed:** each filter remembers which zones and chains you opened. **Collapse all** /
  **Expand all** closes or opens every zone.
- **Sorting:** click a column header (**Lvl**, **Quest**, **XP**) to sort by it. Click it again to
  reverse the order.
- **Search:** click the magnifier in the header row, or press **Ctrl+F**. It finds a quest by its title or
  by a reward's name, for example `staff of westfall`, across every quest. Esc closes it.
- **Details:** click a quest for its details at the bottom, including rewards, reward choices and
  prerequisites. Right-click a quest to mark it, guide it, or show it in Lookup.

**Starting a guide.** Tick quests or whole chains, then click **Start guide**. You get one guide tab that
works like Polestar's Lookup and Dungeons guides:

- Each chain starts at the first quest you haven't done.
- Prerequisites always come first.
- Quests you have already done are left out.
- Quests are ordered nearest giver first.
- When you hand in a quest, the guide is planned again in place, so it always points to the next quest
  in line.

If nothing is ticked, Start guide uses your **marked** quests.

**Marking from item search.** On Lookup's page for an item, every "Quest reward" source row has a star.
- Click the star to mark that quest.
- Right-click it to mark the quest and open it in the Quests section.
- Item tooltips list any marked quest that rewards the item.

Example: search Lookup for two items you want, for example two Westfall quest rewards, and star each
reward quest. Then open Quests and click Start guide. The guide begins with the first quest of each chain
that you still have to do.

## Gear planner

Open it with `/freequest gear`, or from the **Gear** section (the sword) on Polestar's hub rail.

- **Slots:** your gear is laid out as on the character pane. Head to wrist are on the left, hands to
  trinkets on the right, and the weapons along the foot. A dot on a slot means an upgrade is under way
  or ready now.
- **The selected slot:** click a slot to see what you wear there, then its upgrades. The gain is the
  same percentage Polestar's item tooltips show, from your spec's stat weights. A ring or trinket is
  measured against the one in the slot you picked, and hovering it compares it with that one only.
- **What it recommends:**
  - Only items your class can wear (a priest never sees mail), needing at most one level more than you
    have.
  - A higher item is listed only when a quest within reach gives it. For example, a level 28 sees the
    level 30 boots from a level 30 quest, in yellow as "at level 30".
- **Reach:** your **Quests above your level** setting (Quests tab) decides how far above your level the
  quests, dungeons and rares may be. It applies to the sources, never to the item.
- **Sorting:** click a column header. Click it again to reverse the order.
  - **Recommended** (the default) puts first what you're already on: a quest in your log, or a chain
    you've started. Then what's ready now, then what's coming soon. Each group is sorted by gain.
  - **Item** sorts by name.
  - **Closest** puts the fewest steps first: quests left in the chain, a rare, a dungeon.
  - **Lvl** sorts by the level the item needs.
  - **Gain** puts the best upgrade first.
- **Sources** come from the sidebar. Click one to turn it on or off:
  - **Quests** (only quests your character can take)
  - **Dungeons**
  - **Rares & elites**
  - **Vendors** (off by default)
  - **Marked only**

  The auction house, world drops and crafting are never listed.
- **Marking:** star the pieces you want. **Gear guide** then opens one guide to all of them:
  - Pieces a quest gives get their quest chain, from the first quest you haven't done.
  - The rest get Polestar's own Lookup route to their dungeon boss, rare or vendor.
- **The list:** each row shows the gain, the level the item needs (**Lvl**), and what is left to do
  (**Closest**). Hovering a row shows no tooltip.
- **The item page:** click an item to open its page in place of the list. **Back**, **Esc**, or picking
  another slot returns to the list. The page shows:
  - **Compared with what you wear:** only the stats that change, in green or red.
  - **Quest reward:** the whole chain up to the reward. Each quest shows its state, level, giver and zone,
    and the next one to do is highlighted. Buttons: **Guide this chain**, **Show in Quests**, **Lookup**.
  - **Dungeon drop:** what it takes, as a checklist: the dungeon's level against yours, any attunement or
    key and how many steps are left, the dungeon quests you can take, and a warning if the entrance is in
    enemy land.
    - The main button starts Polestar's own guide: its **attunement guide** when one is missing, otherwise
      its **dungeon quests guide**, which picks up the quests and ends at the entrance.
    - **Open dungeon page** goes straight to Polestar's page for that dungeon.
  - **Rare or elite:** where it is, with **Guide me to it**.
  - **Vendor:** where it is and the price, with **Guide me**.
- **Leaving the page:** **Show in Quests**, **Open dungeon page** and **Lookup** take you to that part of
  the hub. A **Back to Gear** button then shows at the top, returning you to the same item page.
- **Marked only** lists every item you marked, from all slots, each with the slot it is for.
- Right-click an item to mark it, guide to it alone, or show it in Lookup.

If something the planner needs is off, a warning on the page says what and offers a fix. The rest of
the page is greyed out until it's turned on:
- If Polestar's **Gear advice** setting is off, the button turns it on.
- If `Polestar_ItemDB` or `Polestar_Codex` is turned off in the addon list, the button turns it on and
  reloads the interface.

The gear planner uses Polestar's gear advice and item data (the `Polestar_ItemDB` addon), and the Lookup
data. It weighs every item once when the section first opens, and again when your gear or level
changes.

The browser reads Polestar's Lookup data (the `Polestar_Codex` addon) for each quest's levels, zone,
prerequisites, rewards and XP. It reads that data the first time the Quests section opens, and waits for
the end of combat if you are fighting.

## Notes

- Places come from Polestar's quest database, the same data behind its map and minimap markers. If the
  database doesn't know a quest, its step says so and has no arrow. Read the quest's log entry instead.
- Free questing (`/polestar free`) only uses Polestar's public addon API (docs/API.md) and the read-only
  lookups of `Polestar.QuestDB`.
- The quest browser builds its guides with Polestar's public Lookup planner API (`Lookup.RegisterPlanner`,
  `API.ReplaceSteps`). It also uses two Polestar internals:
  - the hub section API (`UI.RegisterSection`)
  - Lookup's item page, for the stars
  - Polestar's gear advice (`Gear.CompareToEquipped`, `Gear.Usability`) and `ItemDB`, for the Gear section
  
  Both are guarded, so a Polestar release that changes them only turns those parts off.

License: GPL-3.0-only, as Polestar.
