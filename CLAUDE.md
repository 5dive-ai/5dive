# 5dive CLI — contributor rules

## Hard rule: no real PII in public artifacts (DIVE-1774)

Never put real user ids, emails, phone numbers, or customer PII in anything that
becomes public: PR titles/bodies, commit messages, release notes (`CHANGELOG.md`),
code, or tests. Use placeholders instead:

- Telegram / user ids → `1234567890` (or `<user-id>`)
- Emails → `user@example.com`
- Phones → `+1-555-0100`

This is enforced, not advisory. The `pii-guard` GitHub Action scans every PR
(title, body, commit messages, added diff lines) and the release notes against a
hashed denylist (`.github/pii-denylist.txt`); a hit **fails the check and blocks
merge**. Run it locally before pushing:

```bash
git diff origin/main | grep -E '^\+' | sed 's/^+//' | bash scripts/pii-scan.sh
bash scripts/pii-scan.sh CHANGELOG.md
```

To denylist a new identifier, add its hash (never the plaintext) — see the header
of `.github/pii-denylist.txt`.

> Exception: the commit **author** email `markounik@gmail.com` is intentionally
> public (required for the Vercel team check) and is out of scope.
