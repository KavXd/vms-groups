# VMS Groups

Co-op for **Pokémon Essentials v21.1**, built on top of
[Voltseon's Multiplayer Solution (VMS)](https://eeveeexpo.com/resources/1453/).

Players can form groups, battle NPC trainers and wild Pokémon **side by side**,
and share story progress — so two friends can play through a fangame together.

## Features

- **Groups** (up to 4 players): invite, join, leave, remove, disband.
- **Co-op battles**: two players vs. NPC trainers or wild Pokémon, each
  controlling their own Pokémon. Works from events, or automatically:
  - **Co-op story battles**: gym leaders, rivals and route trainers offer to
    bring a group member on the same map along.
  - **Co-op wild encounters**: grass/cave/water/fishing encounters invite a
    nearby group member.
  - If nobody joins, the battle happens solo as normal.
- **Rewards in co-op battles**: Bag items, catching (whoever throws the ball
  keeps the Pokémon), Exp and EVs for your own Pokémon, Pokédex entries, prize
  money.
- **Shared story progress**: after a co-op trainer win, whatever the event gives
  next (badge, items, switches, self switches, variables) is copied to the
  partner.
- **Party HUD**: group members' location and lead Pokémon HP on the map.
- **Group chat** channel (VMS chat, only shown to your group).
- **Ready check**: the leader asks, everyone answers.
- **Group 2v2**: the leader picks teams for a 4-player VMS multi battle.
- **Double Battle** shortcut to battle a group member directly.
- Everything can be switched on/off per player in **Group → Settings**, and per
  game in `001_Group_Config.rb`.

## Requirements

You need to download these yourself (they aren't included here):

| What | Where |
|---|---|
| Pokémon Essentials **v21.1** | [Eevee Expo – Essentials](https://eeveeexpo.com/essentials/) |
| Voltseon's Multiplayer Solution **v3.0.3** | [Eevee Expo resource 1453](https://eeveeexpo.com/resources/1453/) |
| rainefallUtils | [Eevee Expo resource 1079](https://eeveeexpo.com/resources/1079/) |

## Installation

1. Set up Essentials v21.1 with VMS and rainefallUtils in your `Plugins` folder.
2. Copy `Plugins/VMS Groups` from this repository into your game's `Plugins` folder.
3. Start the game in Debug mode once so the plugins compile.
4. Connect with VMS as usual (pause menu → **Link Play**). A **Group** option
   appears in the pause menu while connected.

`Plugins/VMS AutoTest` and the `autotest` folder are optional, for testing (see below).
Don't ship `VMS AutoTest` in a released game.

## Using co-op battles in events

Replace the usual battle commands in an event's Script command:

```ruby
VMS.coop_trainer_battle(:YOUNGSTER, "Ben")      # same arguments as TrainerBattle.start
VMS.coop_wild_battle(:PIDGEY, 5, :RATTATA, 5)   # same arguments as WildBattle.start
```

They return the same values as the normal commands, and fall back to a solo battle
if no group member is free or the invite is declined. With **Co-op Story Battles**
on, regular trainer events become co-op automatically — no event changes needed.

## How co-op battles stay in sync

Both games simulate the same battle with the same random seed, foes, weather and
backdrop. Each player picks moves for their own Pokémon; only the host runs the
NPC's AI and sends its choices. Exp is handed out after the battle on each
player's own game, so a level-up or new move can't make the two battles differ.
If a player disconnects, the AI takes over their Pokémon.

## Configuration

All settings are in `Plugins/VMS Groups/001_Group_Config.rb`, with comments.
Highlights:

- `COOP_STORY_DEFAULT`, `COOP_AUTO_WILD` – default on/off for automatic co-op.
- `COOP_AUTO_DISTANCE`, `COOP_STORY_DISTANCE` – how close a partner must be.
- `COOP_ALLOW_ITEMS`, `COOP_ALLOW_CATCHING`, `COOP_EXP` – rewards in co-op battles.
- `COOP_SHARE_*` – what shared story progress copies, plus exclusion lists for
  switches/variables your events use temporarily.
- `COOP_GUEST_BLACKS_OUT` – whether the player who joined can black out.

## Testing (optional)

`VMS AutoTest` runs two copies of your game against each other on one PC, with the
AI playing both sides, and checks that both games' battles stay identical turn by
turn (plus groups, catching, Exp and shared progress). It only activates when the
`VMS_AUTOTEST` environment variable is set, so normal play is unaffected.

1. Copy `Plugins/VMS AutoTest` into your `Plugins` folder and the `autotest`
   folder into your game folder.
2. From your game folder, in Git Bash (Ruby must be installed):

   ```bash
   bash autotest/run_autotest.sh
   ```

Results are printed at the end; full logs are written to `autotest_logs/`. The test
uses the Essentials demo's Lappet Town (map 2) and the `YOUNGSTER, Ben` trainer —
change `TEST_MAP` and the trainer in `001_AutoTest.rb` for your own game.

## Limitations

- Only tested with Essentials v21.1 and VMS 3.0.3.
- Exp messages appear after the battle screen closes, not inside the battle.
- The held Exp. Share item isn't counted in co-op battles (Exp All is).
- Shared progress copies everything an event changes *after* the battle; add
  temporary switches/variables to the exclusion lists.
- Group chat is filtered on each player's game, not by the server, so it isn't
  truly private.

## Credits

- **VMS Groups**: KavXd
- **Voltseon's Multiplayer Solution**: Voltseon, ThankfulHyena170
- **rainefallUtils**: rainefall
- **Pokémon Essentials**: Maruno, Poccil (Peter O.) and the Essentials contributors

Pokémon is © Nintendo, Creatures Inc. and GAME FREAK inc. This is a fan project,
not affiliated with or endorsed by them.
