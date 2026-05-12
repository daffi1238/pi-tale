# Contributing to pi-tale

Thanks for considering a contribution. pi-tale is built in the open and
small, focused improvements are the most valuable kind.

## Ground rules

1. **ARM64 compatibility is mandatory.** Every Docker image we add must
   ship an official `arm64` (or multi-arch) tag. We test on Raspberry Pi
   4 and 5.
2. **No `:latest` tags in production compose files.** Pin every image to
   a concrete version (e.g. `prom/prometheus:v2.55.1`). `:latest` is only
   acceptable in throwaway examples that are clearly labelled as such.
3. **No secrets in the repo.** Anything sensitive lives in `compose/.env`
   (which is git-ignored). New variables must be documented in
   `compose/.env.example` with sensible defaults or `CHANGE_ME` markers.
4. **Scripts must be idempotent.** Running `bootstrap/install.sh` twice
   must not break anything. Detect state, then act.
5. **Fail loud, fail clear.** When a script can't continue, print an
   error message that says what failed and how to fix it.
6. **Compose stays modular.** Core, UniFi, probes, and extras live in
   separate files; users opt in with `-f`.
7. **Document user-visible changes** in `CHANGELOG.md` following
   [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Update
   `README.md` or files under `docs/` when behaviour changes.
8. **English in code, comments, docs and commit messages.**

## Workflow

1. Open an issue first for non-trivial changes so we can align on scope.
2. Branch from `main`: `git checkout -b feat/<short-name>`.
3. Keep commits small and focused. Conventional Commits style is welcome
   but not required.
4. Run any relevant linters / syntax checks before pushing:
   - Shell scripts: `shellcheck bootstrap/*.sh scripts/*.sh`
   - YAML: `yamllint compose/ prometheus/ alertmanager/`
   - Python: `ruff check exporters/`
5. Update docs and `CHANGELOG.md`.
6. Open a PR describing what changed, why, and how you tested it.

## Local testing

The fastest way to sanity-check a change is on a real Pi. If you don't
have one handy, an ARM64 VM works for everything except the WiFi probe
(which needs a real monitor-mode adapter).

```bash
docker compose -f compose/core.yml --env-file compose/.env config   # validate
docker compose -f compose/core.yml --env-file compose/.env up -d
```

## Reporting bugs

Please include:

- Raspberry Pi model and OS version.
- `docker --version` and `docker compose version`.
- Relevant logs (`docker compose logs <service>`).
- What you expected vs. what happened.

## License

By contributing, you agree that your contributions will be licensed under
the Apache License 2.0, the same license as the project.
