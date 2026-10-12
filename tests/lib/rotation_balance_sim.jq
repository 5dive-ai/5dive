# DIVE-6106 week simulation. Prepended with ROTATION_BALANCE_JQ by the harness,
# so it calls the PRODUCTION balance_decide / balance_rank, never a copy.
#
# Input: {balance: bool, knobs, ticks, tickSecs, cap7, cap5, win5,
#         accounts: [names], seats: [{name, acct, rate, fresh, seed, pinBusy?}]}
# Model, per tick: a seat is working a task or between tasks. Task and gap
# lengths come from a per-seat LCG, so the trace is deterministic. A working
# seat spends `rate` units on its account; a seat whose account is walled
# (5h or 7d >= maxPct) cannot spend (blocked). EVERY seat is offered to the
# policy EVERY tick, with the boundary facts true only on the tick it is about
# to start a new task — so a mid-turn seat reaching a move is a gate failure
# the harness can count, not a case the simulator never asks.
def lcg: (. * 75 + 74) % 65537;
def pct7($s; $a): ($s.used7[$a] // 0) * 100 / $s.cap7;
def pct5($s; $a): (([$s.win[$a][]] | add) // 0) * 100 / $s.cap5;
def near($s; $a; $k): (pct5($s; $a) >= $k.maxPct) or (pct7($s; $a) >= $k.maxPct);
def acct_rows($s):
  [ $s.accounts[] as $a
    | {name:$a, fivePct: pct5($s; $a), sevenPct: pct7($s; $a), asOf: $s.now,
       activeSeats: ([ $s.seats[] | select(.acct == $a and .working) ] | length)} ];
def nearwall_pick($s; $i; $k):
  # The existing path: destinations with both windows under maxPct. Balance
  # off = pool order (alphabetical, as rotation_eligible_accounts emits it);
  # balance on = under-the-5h-floor first, each half in balance_rank order.
  [ acct_rows($s)[] | select(.name != $s.seats[$i].acct and .fivePct < $k.maxPct and .sevenPct < $k.maxPct) ] as $d
  | if ($d | length) == 0 then null
    elif $s.balance then
      ((([ $d[] | select(.fivePct < $k.fiveFloor) ] | if length == 0 then [] else balance_rank($k.tie) end)
        + ([ $d[] | select(.fivePct >= $k.fiveFloor) ] | if length == 0 then [] else balance_rank($k.tie) end))
       | first | .name)
    else ($d | sort_by(.name) | first | .name) end;
def step($k):
  . as $s0
  | .now += .tickSecs | .fleetMoved = false
  | reduce range(0; .seats | length) as $i (.;
      . as $s
      | $s.seats[$i] as $seat
      | ((($seat.working | not) and ($seat.left <= 0))) as $boundary
      | (if $boundary and near($s; $seat.acct; $k) then
           nearwall_pick($s; $i; $k) as $to
           | if $to != null then .seats[$i].acct = $to | .moves += [{t:$s.now, seat:$seat.name, kind:"near-wall", to:$to, busy:false}] else . end
         elif $s.balance then
           ({current:$seat.acct, now:$s.now, seatLastMoveAt:$seat.lastMove, fleetMoved:$s.fleetMoved,
             boundary:{idle: ($seat.working | not), fresh:$seat.fresh, newTask:$boundary},
             accounts: acct_rows($s), knobs:$k} | balance_decide) as $v
           | if $v.move then
               .seats[$i].acct = $v.to | .seats[$i].lastMove = $s.now | .fleetMoved = true
               | .moves += [{t:$s.now, seat:$seat.name, kind:"balance", from:$v.from, to:$v.to,
                             busy:$seat.working, fromSeven:$v.fromSeven, toSeven:$v.toSeven}]
             else . end
         else . end)
      # advance the seat's own schedule
      | .seats[$i] as $st
      | if $st.working then
          (if $st.left <= 1 then .seats[$i].working = false | .seats[$i].seed = ($st.seed | lcg)
                              | .seats[$i].left = (if $st.pinBusy then 0 else ($st.seed % 7) end)
           else .seats[$i].left = ($st.left - 1) end)
        elif $st.left <= 0 then
          .seats[$i].working = true | .seats[$i].seed = ($st.seed | lcg)
          | .seats[$i].left = (if $st.pinBusy then 100000 else (6 + ($st.seed % 13)) end)
        else .seats[$i].left = ($st.left - 1) end)
  # spend: a working seat on a walled account is blocked
  | . as $s
  | reduce range(0; .seats | length) as $i (.;
      .seats[$i] as $st
      | if ($st.working | not) then .
        elif near($s; $st.acct; $k) then .blocked += 1
        else .spent[$st.acct] = ((.spent[$st.acct] // 0) + $st.rate) | .done += $st.rate end)
  | . as $s
  | .used7 = (reduce $s.accounts[] as $a (.used7; .[$a] = ((.[$a] // 0) + ($s.spent[$a] // 0))))
  | .win = (reduce $s.accounts[] as $a (.win; .[$a] = ((.[$a] + [($s.spent[$a] // 0)]) | .[-($s.win5):])))
  | .spent = {}
  | ([ $s.accounts[] as $a | pct7(.; $a) ]) as $p
  | .spread = ((($p | max) - ($p | min)) as $sp | if .now >= .warmup then ([.spread, $sp] | max) else .spread end)
  | .final = $p;
. as $in
| $in.knobs as $k
| { now: 0, tickSecs: $in.tickSecs, cap7: $in.cap7, cap5: $in.cap5, win5: $in.win5,
    warmup: $in.warmup, balance: $in.balance, accounts: $in.accounts,
    used7: {}, win: (reduce $in.accounts[] as $a ({}; .[$a] = [])), spent: {},
    seats: [ $in.seats[] | . + {working:false, left:0, lastMove:null, pinBusy:(.pinBusy // false)} ],
    moves: [], fleetMoved:false, blocked:0, done:0, spread:0, final:[] }
| reduce range(0; $in.ticks) as $_ (.; step($k))
| { balance, spread: (.spread | floor),
    final: (.final | map(floor)), finalSpread: ((.final | max) - (.final | min) | floor),
    moves: (.moves | length),
    balanceMoves: ([.moves[] | select(.kind == "balance")] | length),
    nearWallMoves: ([.moves[] | select(.kind == "near-wall")] | length),
    busyMoves: ([.moves[] | select(.busy)] | length),
    pinnedMoves: ([.moves[] | select(.seat == "pinned")] | length),
    nonFreshMoves: ([.moves[] | select(.kind == "balance" and (.seat == "main" or .seat == "marketing"))] | length),
    maxSeatMovesIn3h: ([.moves[] | select(.kind == "balance")] | group_by(.seat)
                       | map(. as $m | [ $m[] | .t as $t | [ $m[] | select(.t >= $t and .t < $t + 10800) ] | length ] | max) | max // 0),
    maxMovesPerTick: ([.moves[] | select(.kind == "balance")] | group_by(.t) | map(length) | max // 0),
    blockedTicks: .blocked, workDone: (.done | floor),
    byAccount: ([.seats[] | .acct] | group_by(.) | map({(.[0]): length}) | add) }
