# Участие в разработке

Спасибо за интерес к **[Setup Server Stack](https://github.com/commercedeployer/setup-server-stack)**.

**English:** [CONTRIBUTING.md](CONTRIBUTING.md)

## Как предложить изменение

1. Форк репозитория и ветка от `main`.
2. Держите `setup-server-stack.sh`, `lib/`, `docker-compose.yml`, `.env.example` согласованными между собой.
3. Обновите **INSTALL.md** и **INSTALL.ru.md**, если меняется поведение для пользователя.
4. Не коммитьте `.env`, `.env.stack`, `.setup-server-stack-secrets`, `acme.json`, сгенерированные `config/*`.
5. Перед PR: `bash tests/run-ci.sh` (нужен Docker; `shellcheck` опционален — fallback через Docker-образ). То же на GitHub Actions (`.github/workflows/ci.yml`).
6. Pull request с кратким описанием «зачем» и чеклистом ручной проверки на VPS (если применимо).

## Локальные проверки

Из каталога `setup-server-stack/` (Git Bash или WSL на Windows):

```bash
bash tests/run-ci.sh
```

**shellcheck**, **docker compose config** на фикстурах `tests/fixtures/`, юнит-тесты `tests/validate-lib.sh`.

## Стиль

- Один путь поведения, без legacy-shims (проект greenfield).
- Секреты — только через `.env` / `.setup-server-stack-secrets`, не в репозитории.
- Именование продукта: **Setup Server Stack**, не «head stack».
- **Комментарии в коде и сообщения установщика — на английском.** Гайды: EN (`README.md`, `INSTALL.md`) + RU (`README.ru.md`, `INSTALL.ru.md`).

## Вопросы

Для багов и идей используйте Issues в GitHub. Уязвимости — см. [SECURITY.ru.md](SECURITY.ru.md).
