# bladecount

An [Ashita v4](https://www.ashitaxi.com/) addon for Final Fantasy XI that tracks your Chaosbringer kills for the Dark Knight quests **Blade of Darkness** and **Blade of Death**.

The sword's kill count carries on between the two quests: Blade of Darkness needs 100 kills, and Blade of Death needs 100 more, so the count reaches 200. The window shows Blade of Darkness up to 100, then switches to Blade of Death up to 200, and says what to do when each is done. If you drop the sword and get a new one, its count starts again from zero.

## How it works

The game stores the kill count on the Chaosbringer itself, but the copy your client holds never updates. **Refresh** moves the sword into your Satchel (or Sack or Case) and back. When it moves, the server's update for the inventory slot the sword left carries the current count, which is the same value Windower's LatentChecker reads.

Between refreshes, a **live counter** adds kills that should count: "You defeat ..." where your last action on that monster was a regular melee swing with Chaosbringer in your main hand. Weapon skill, spell and ability kills, and kills landed by Trusts or party members, are not counted, matching the quest's rules.

## Install

Copy the `bladecount` folder into `Ashita/addons`, then:

```
/addon load bladecount
```

## Commands

`/bladecount` or `/bod`

| Command | What it does |
|---|---|
| `/bod` | Show or hide the window |
| `/bod refresh` | Read the current count from the server (resets your TP; the sword is re-equipped afterwards) |
| `/bod fetch` | Bring the sword back from your Satchel, Sack or Case and equip it (use this if a refresh stops partway) |
| `/bod status` | Print the counts in chat |
| `/bod opacity <0-100>` | Set the window's background opacity (also a slider under Settings in the window; 0 is fully clear) |
| `/bod reset` | Zero the live counter |

The window appears only while you have a Chaosbringer in your inventory or wardrobes. Refresh needs a free slot in your Satchel, Sack or Case, plus a free inventory slot if the sword is in a wardrobe; a sword taken from a wardrobe ends up in your inventory.

The live counter is an estimate. Refresh now and then to get back to the real number.
