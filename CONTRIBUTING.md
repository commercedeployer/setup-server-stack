# Contributing

Thank you for your interest in **[Setup Server Stack](https://github.com/commerce-deployer/setup-server-stack)**.

**Русский:** [CONTRIBUTING.ru.md](CONTRIBUTING.ru.md)

## How to propose a change

1. Fork the repository and branch from `main`.
2. Keep `setup-server-stack.sh`, `lib/`, `docker-compose.yml`, and `.env.example` consistent with each other.
3. Update **INSTALL.md** and **INSTALL.ru.md** if user-facing behavior changes.
4. Do **not** commit `.env`, `.env.stack`, `.setup-server-stack-secrets`, `acme.json`, or generated `config/*`.
5. Before opening a PR, run local checks: `bash tests/run-ci.sh` (requires Docker; `shellcheck` optional — Docker image used as fallback). The same suite runs on GitHub Actions (`.github/workflows/ci.yml`).
6. Open a pull request with a short “why” and a manual VPS checklist when applicable.

## Local checks

From `setup-server-stack/` (Git Bash or WSL on Windows):

```bash
bash tests/run-ci.sh
```

Runs **shellcheck** on shell scripts, **docker compose config** on CI fixtures in `tests/fixtures/`, and **validation unit tests** in `tests/validate-lib.sh`.

## Style

- One code path, no legacy shims (greenfield project).
- Secrets only via `.env` / `.setup-server-stack-secrets`, never in the repo.
- Product name: **Setup Server Stack** (not “head stack”).
- **Code comments and installer CLI messages in English.** User guides: English primary (`README.md`, `INSTALL.md`) plus Russian mirrors (`README.ru.md`, `INSTALL.ru.md`).

## Questions

Use GitHub Issues for bugs and ideas. For vulnerabilities, see [SECURITY.md](SECURITY.md).
