# TODO

Open work only, in the order it is done. One item per branch; it lands
before the next starts (CLAUDE.md). The PR that finishes an item deletes
its line and says in its description which docs it updated. Finished work
lives in git history and the merged PRs, not here.

## Next

- [ ] Docs catch-up: `docs/mekhq-map.md` rows for `keys.zig` and `digest.zig`; `docs/tui.md` and `GAMEPLAY.md` describe strict command parsing (leftover words refused, bare `autoadmit` toggles), `refused: <sentence>` messages, and the Forces `+` refusing after the name; `docs/tui.md` loses its "Build order" section and "(Stage 12F)" tags; ARCHITECTURE describes the key-binding tables and `docs/verify-contract.sh`; CLAUDE.md names `docs/verify-contract.sh`.

## Adopting the revised contract

`docs/coding-contract-proposed-updated.md` becomes the contract when its full
gate passes; until then `docs/coding-contract.md` governs.

- [ ] Subsystem behaviour off `GameState` (rule 77): the hash into `digest.zig`, pricing, staffing and the rest into their owning modules.
- [ ] Full failure atomicity (rules 11-14, 69): validate / prepare / commit in every compound command, log lines and effects prepared before the first mutation, staged RNG, and one failure-injection test per mutation pattern that works under the campaign arena.
- [ ] SQL foreign keys, unique keys and checks through a table-rebuild migration, with `PRAGMA foreign_keys` on every connection (rule 50).
- [ ] CI clean-package build: a tree holding only the `build.zig.zon` paths builds (rule 66).
- [ ] Windows: target-gated terminal (console API, raw mode), resize without SIGWINCH, a music player without `afplay`, paths; CI builds macOS, Linux and Windows (rule 65).
- [ ] `docs/audit-response.md` addendum: failure atomicity is met by prepare/commit helpers and one failure-injection test per pattern, not a transaction framework.
- [ ] Rule citations renumbered to the new contract in one PR: `src/`, docs, CLAUDE.md (hard rules; the "section 9 checklist" becomes section 11), test names.
- [ ] Adoption PR: the proposal replaces `docs/coding-contract.md` as "Coding contract", every gate command passes on that commit, and the remaining violations are listed as rule-87 exceptions: the seven modules over 1,000 lines (queries, commands, app, store, battle, state, contract_events), each tied to a split scheduled after adoption, and the wizard's pre-session `commands.execute`.

## Tests

- [ ] Smoke coverage still missing: the GAME OVER modal (needs a saved campaign already past all credit as a fixture), the exact 120-column layout boundary, and the refusal branch of each confirm.

## Data verification (needs the sourcebooks)

- [ ] `contract.operationsMultBp`: check each contract kind's multiplier against the CamOps contract payment table and cite the page (rule 6).
- [ ] Dragoons rating bands (`tuning.zon` `rating`): confirm the source (FM: Mercenaries rather than CamOps?) and cite the page.

## Not scheduled

Design ideas, not defects; each needs its design in ROADMAP.md first.

- Per-site hospital and doctor capacity (audit #7).
- A mobile field base as a buyable Repair support lance, adding to the repair push beyond the Logistics lance's workshop.
