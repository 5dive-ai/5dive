# Offline root certificate (DIVE-7888)

Boxes that hold 5dive's offline root key take an update file only when the root
has certified the key that signed it. This folder holds that certificate, and
the offline-update workflow embeds it in every file it publishes.

Four files, all made at the owner's key ceremony, all PUBLIC:

- `signing-key.json` — the signing key's public half, its `key_id` and its expiry (`not_after`)
- `signing-key.sig` — the root's signature over `signing-key.json`, exact bytes
- `revoked.json` — the root's list of revoked signing keys, with a `serial`
- `revoked.sig` — the root's signature over `revoked.json`, exact bytes

Commit them byte for byte as the ceremony wrote them: the signatures cover the
exact bytes.

A new `revoked.json` replaces the checked-in one only with a HIGHER `serial`
(or the same bytes). Two different lists with one serial cannot be ordered: a
box then applies both, and the ceremony page refuses to block a key on list 1.

Only public files go here. Never the root's private key, never the signing
key's private key (that stays in the `OFFLINE_UPDATE_SIGNING_KEY` repo secret).

While this folder holds no certificate, files are built as before and checked
by the pinned release key.
