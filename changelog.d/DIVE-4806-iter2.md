## Unreleased — fix(tests): the EPIPE guard detects the ingredient, not the writer I had in front of me (DIVE-4806)

The first fix for this row converted three `printf … | grep -q` sites and added arm **E7** to stop
the shape coming back. E7's pattern was `printf[^|]*\| *grep -q`. Four lines below it, arm **F6**
was `"$BIN" board -h 2>/dev/null | grep -q 'contract-version'` — a live instance of the same
defect, in the same file, returning **zero** matches from the guard that was added to find it.
Measured by the verifier at the merged sha: that pipeline failed **13 of 60** runs while the
herestring form failed 0 of 60, and the string is in the help text twice. So `test-installed-host`
could still red on a true property after the row was called fixed.

`printf` is not one of the hazard's ingredients. The ingredients are `pipefail`, a reader that can
exit before end-of-input, and a writer with a write still to come. **E7 now matches any
`| grep -q`**, and the remaining sites are converted rather than exempted: E2's `awk` over
`src/main.sh`, F6's `board -h`, and both mutation arms' `board --contract-version`.

**The exemption list is empty on purpose.** The tempting scope statement was "exempt the sites
whose payload drains before the reader exits" — a dozen lines of `awk`, a one-line
`--contract-version`. It is not signable. `5dive board -h` emits **838 bytes** and the process
makes **258** separate `write(2)` calls; the payload's byte count is not the ingredient, and a
shell writer's write count is not something a reader of the test file can check. An exemption
nobody can test is the same blind spot written as prose, so the arm asserts **zero sites, zero
exemptions** — the one scope that needs no argument. A future site gets converted, not listed.
