# TLS certificates

Use this directory for reusable Traefik TLS certificates. On the server this is always `$STACK_ROOT/certs`; there is no separate `.env` setting for this path.

Use one folder per exact host:

```text
certs/<host>/fullchain.pem
certs/<host>/privkey.pem
```

Examples:

```text
certs/portainer.example.com/fullchain.pem
certs/portainer.example.com/privkey.pem

certs/registry.example.com/fullchain.pem
certs/registry.example.com/privkey.pem
```

The certificate can be from Let's Encrypt, a hosting control panel, or a paid CA. Traefik uses it the same way.

How modes use this directory:

- `TRAEFIK_CERT_MODE=auto`: uses `certs/<host>/` first; if no pair exists, it asks production Let's Encrypt.
- `TRAEFIK_CERT_MODE=provided`: uses only `certs/<host>/`; it never asks Let's Encrypt.
- `TRAEFIK_CERT_MODE=letsencrypt`: ignores `certs/<host>/` for routing and asks production Let's Encrypt.

After successful production Let's Encrypt issuance in `auto` or `letsencrypt` mode, the installer exports the issued certificate into the same `certs/<host>/` structure on the server. Existing `fullchain.pem` or `privkey.pem` files are kept and are not overwritten.

Private keys are secrets. Do not commit real certificate folders.

Note: setup-server-stack may also create service files like `registry-token.pem` in this directory on the server. User TLS certificates should be kept only in host-named folders.
