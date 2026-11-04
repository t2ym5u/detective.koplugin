# Changelog

## [1.1.2] - 2026-11-04

### Changed
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.
- Uses less memory: the case names and places load only for the language
  played, and are freed when the game closes.

## [1.1.1] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.1.0] - 2026-11-02

### Added
- Multiplayer mode: also listed as "Detective · multiplayer" under Tools →
  Games → Party & quiz, and switchable in the game (menu → Mode). The table
  investigates one case together; the clues come out one at a time (Next
  clue), anyone may accuse once per case (Accuse asks who is accusing). A
  wrong accusation rules that player out of the case; the first right one
  wins it and scores 1 point plus 1 per clue still hidden. A match is 1, 3,
  5 or 7 cases (Rounds) and ends on a final scoreboard. Players, their names
  and the match in progress are saved; the solo case is kept apart.
- Separate multiplayer rules (Rules opens the rules of the mode played, with
  a button to read the other mode's).

## [1.0.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.0.0] - 2026-10-30

### Added
- First release: generated logic-deduction cases (3×3 easy, 4×4 medium,
  5×5 hard), each with exactly one solution and no redundant clue.
- Logic grid with one tab per pair of categories, auto-cross on a dot, Undo,
  tap-to-grey clues, two-step hints, Accuse (culprit, place, object), Show
  solution and a Daily Challenge.
- Cases in French and English (own Language setting), with famous suspects,
  monuments and objects (about 90 crimes and 180 suspects per language, five
  theme packs); interface in English, French, Spanish and German.
