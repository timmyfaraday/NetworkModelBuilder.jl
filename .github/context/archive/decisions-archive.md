# Decisions archive

Superseded wording for decisions that were later changed, one line per id. Read only to resolve an
old decision id cited in a commit, PR or note.

- D48 · superseded 2026-10-10 by D50: a branch's `length_km` was checked finite and `>= 0`, so NaN was refused; NaN is now valid and means unknown.
- D61 · superseded 2026-10-11 by D67 and D69: constraints were left unnamed and said to be named in the next step (D67); the keyword was `set_string_name`, default true, a caller's `jump_model` left as it came with true (D69: `debug_mode`, default false).
- D67 · superseded 2026-10-11 by D69: `set_string_name` covered constraints, default true; it is `debug_mode`, default false.
- D65 · superseded 2026-10-11 by D70: an id had one shape per key; it has one per key within a formulation.
- D50 · partly superseded 2026-10-12 by D90: the `s_max` of a branch was checked `>= 0`, so a rating of zero was accepted; it is `> 0`, and so is a transformer's.
