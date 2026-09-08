- `5dive export` now produces a `loops:` block that its own parser accepts. A recurring
  row with no cadence can never fire, so it is reported and left out instead of exported
  as an invalid loop that refused the whole document at re-import; a title that slugifies
  to nothing gets a stable derived id; and two titles colliding at the 64-character id cap
  export as two distinct ids rather than a duplicate key.
