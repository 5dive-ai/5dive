## Unreleased — fix(export): `5dive export` produces a `loops:` block its own parser accepts (DIVE-4022)

<!-- DIVE-4177: heading repaired. This entry had no `## Unreleased` first line, so every cut
     since it was written SKIPPED it and it never reached a release page. It folds into the
     next cut and will be labelled with that version, which is later than the version the
     change itself shipped in — accepted deliberately: a late entry is recoverable, a
     dropped one is not. -->

- `5dive export` now produces a `loops:` block that its own parser accepts. A recurring
  row with no cadence can never fire, so it is reported and left out instead of exported
  as an invalid loop that refused the whole document at re-import; a title that slugifies
  to nothing gets a stable derived id; and two titles colliding at the 64-character id cap
  export as two distinct ids rather than a duplicate key.
