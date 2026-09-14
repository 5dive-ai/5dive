## Unreleased — fix(selfcheck): the t2-forge probe's fixture gate names its outcomes (DIVE-4462 follow-up)

DIVE-4462 (#954) made `task need` refuse a gate whose `--options` are single characters, because
those options are the buttons a person taps. The `t2-forge` selfcheck probe seeded its own fixture
gate with `--options="A|B"`, so from that merge on the probe reported `not-reached|no-tier2-gate` in
every environment and `selfcheck-union` correctly reds main — a probe that is excusably not-reached
everywhere is permanently unmeasured. The fixture now names two outcomes ("take the left lane" /
"take the right lane") and both arms answer with the spelled-out value. Probe: pass in pristine;
`selfcheck_unit` 33/33, `selfcheck_union_unit` 21/21.
