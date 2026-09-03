# Signed event triggers

`5dive trigger` turns an authenticated external event into an ordinary task. The receiver does not start an agent: it verifies the exact request bytes, records and deduplicates the delivery, evaluates the configured rule, and ends at the existing queue. Heartbeat routing, gates, verifier handoffs, and traces then work exactly as they do for any other task.

## Configure a GitHub trigger

Generate a high-entropy webhook secret and pass it on stdin so it never appears in the process list:

```sh
openssl rand -hex 32 | sudo 5dive trigger add github \
  --name=github-issues \
  --event=issues.labeled \
  --repo=acme/app \
  --where='label.name == "5dive"' \
  --role=engineering \
  --task-title='Review labeled GitHub issue' \
  --secret-from-stdin
```

Configure the GitHub webhook URL as `https://agents.example.com/hooks/github-issues`, choose `application/json`, paste the same secret, and subscribe only to Issues events. GitHub deliveries must include `X-Hub-Signature-256`, `X-GitHub-Delivery`, and `X-GitHub-Event`; an `issues` event is matched with its authenticated payload action as `issues.labeled`.

## Configure a generic signed webhook

```sh
printf '%s\n' "$WEBHOOK_SECRET" | sudo 5dive trigger add webhook \
  --name=payment-failure \
  --event=payment.failed \
  --role=support \
  --max-pending=25 \
  --secret-from-stdin
```

The sender POSTs JSON to `https://agents.example.com/hooks/payment-failure` with:

- `X-5dive-Signature-256: sha256=<hex HMAC-SHA256 over the exact body>`
- `X-5dive-Event: payment.failed`
- `X-5dive-Delivery: <globally unique sender delivery ID>` (or `Idempotency-Key`)

If neither delivery-ID header is present, 5dive falls back to a payload hash plus an hourly bucket. A sender-provided unique ID is strongly preferred because its idempotency does not depend on timing.

## Serve behind HTTPS

The built-in receiver is HTTP and defaults to loopback:

```sh
sudo 5dive trigger serve --listen=127.0.0.1:8740
```

Run it under your process supervisor and terminate HTTPS at the existing reverse proxy. An nginx location can be as small as:

```nginx
location /hooks/ {
    client_max_body_size 1m;
    proxy_connect_timeout 5s;
    proxy_read_timeout 30s;
    proxy_pass http://127.0.0.1:8740;
}
```

Expose only `/hooks/`; `/healthz` is intended for a local health probe. There is no unauthenticated task-creation route. The receiver requires `Content-Length`, caps the body at 1 MiB globally (and at the trigger's lower `--max-bytes` value), and times out incomplete requests.

## Operations and security

```sh
5dive trigger ls
5dive trigger show github-issues
5dive trigger deliveries github-issues
sudo 5dive trigger disable github-issues
sudo 5dive trigger enable github-issues
printf '%s\n' "$NEW_SECRET" | sudo 5dive trigger rotate github-issues --secret-from-stdin
sudo 5dive trigger replay 42
```

Signing secrets and authenticated raw payloads are owner-only files below `/var/lib/5dive/triggers`; the group-readable task database stores references and bounded normalized metadata, not secret values. Invalid signatures are recorded without parsing or preserving the body. Replay uses the sender's original signature and the normal verification path, so it cannot bypass authentication; rotation may intentionally make an older delivery unreplayable.

A valid signature authenticates the sender, not the payload's instructions. Every task body marks event content as external and untrusted, and rules support only exact event/action matching plus small equality filters for `label.name`, `branch`, and `actor`. No payload field is interpolated into a command.

`--max-pending=N` applies backpressure using the number of still-open tasks created by that trigger. `--on-overflow=park` (the default) records excess delivery work without spawning another task; `fail` instead returns a conflict. Both outcomes remain in `trigger deliveries` and the local UI's Triggers view.
