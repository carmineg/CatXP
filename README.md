# CatXP

A tiny, cat-themed XP per hour tracker for **World of Warcraft: Forever**. One small window
with a cat portrait, five rate windows, a graphs window, a leaderboard with live standings,
all-time records and races against your friends, and a bank of 2,275 cat facts dealt like a
shuffled deck, so every announcement ends with a different one. Optional gold per hour tracking
(looted coin, quest coin and the vendor price of what you pick up). No libraries.

- The addon is the [CatXP](CatXP/) folder. Its [README](CatXP/README.md) has the full tour:
  the window, the cats, the commands, the settings and the leaderboard protocol.
- **Install**: copy the `CatXP` folder into `World of Warcraft\_forever_\Interface\AddOns`
  and restart the game. Type `/catxp` in game for the commands.
- [tools](tools/) holds the headless test harness (`run_tests.py <addon dir>`, needs
  `pip install lupa`), the fact bank generator (`build_facts.py`, sources in `tools/facts/`),
  the pixel-art portrait generator (`make_cats.py`, needs Pillow) and `package.py`, which zips
  a release.

Release zips are attached to GitHub Releases rather than committed.

MIT licensed.
