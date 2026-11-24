# bladecount

An [Ashita v4](https://www.ashitaxi.com/) addon for Final Fantasy XI that tracks your Chaosbringer kills for the Dark Knight unlock quest **Blade of Darkness** (100 kills needed).

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
| `/bod status` | Print the counts in chat |
| `/bod reset` | Zero the live counter |

The window appears only while you have a Chaosbringer in your inventory or wardrobes. Refresh needs a free slot in your Satchel, Sack or Case, plus a free inventory slot if the sword is in a wardrobe; a sword taken from a wardrobe ends up in your inventory.

The live counter is an estimate. Refresh now and then to get back to the real number.
