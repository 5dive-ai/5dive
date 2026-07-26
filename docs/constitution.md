# Company constitution (`constitution.yaml`)

5dive can load governance policy from `${STATE_DIR}/constitution.yaml` (normally
`/var/lib/5dive/constitution.yaml`). Set `FIVEDIVE_CONSTITUTION_FILE` to exercise a
candidate in an isolated environment. If the file is absent or malformed, the
loader atomically uses the shipped pre-constitution defaults; it never applies a
partial document.

The whole file is parsed as YAML. There is no Markdown body and no `---`
frontmatter fence: human rationale lives in `#` comments, which are covered by
the sealed digest but never parsed as policy.

```yaml
# Company governance policy. Comments are digest-covered but not parsed.
council:
  bench: council
quorum: majority
thresholds:
  ordinary: majority
  promote: majority
  demote: 2/3
  expel: 2/3
  constitutional:
    rule: fraction
    value: 0.6666666666666666
    quorum: all
    require_quorum: true
veto:
  principals: [human:main]
  hold_secs: 0
  posthoc_secs: 172800
hard_gates:
  spend_billing: 'spend|billing|invoice|charge|payment|refund|subscription|price|pricing|\$[0-9]|€[0-9]'
  public_comms: 'publish|public post|announce|launch post|press|customer email|email customers|newsletter|blast'
  secrets: 'secret|credential|api key|token|password'
  destructive: 'delete|destroy|teardown|wipe|purge|drop[^.]{0,20}table|truncate|irreversible|revoke|dns|domain transfer'
ship:
  require_ci: true
comms:
  public_requires_human: true
# Why these rules: explain the company's governance choices in comments like this.
```

The v0 parser accepts two-space mappings, scalar values, and inline arrays.
`hard_gates` values are case-insensitive POSIX ERE patterns. Supplying the
`hard_gates` map replaces the shipped class map, so an organization can add or
remove a class without patching the CLI. Bash compile-probes the combined
pattern before using it; if Bash rejects it, the entire loaded map is discarded
and task gate tiering warns and falls back to the shipped tier-2 floor.

Live consumers:

- Council tally reads the configured bench pointer, per-class thresholds, and
  quorum.
- Founder-veto offers/windows read `veto` (the environment remains the fallback
  only when no constitution exists).
- Task gate tiering compiles `hard_gates` into the tier-2 human-only floor.
- `ship` and `comms` are parsed and digest-coverable soft-policy data; they are
  not execution rules in v0.

CNCL-14 is the loader/consumer layer. Genesis digest sealing, drift verification,
and the constitutional-motion-only amendment path are CNCL-15; until that lands,
operators should treat direct edits as setup/testing, not a ratified amendment.
