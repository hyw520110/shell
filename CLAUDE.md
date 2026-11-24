# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A collection of Bash automation scripts for ops and dev workflows: dev environment setup, middleware deployment, monitoring, security auditing, CI/CD, and an AI toolchain manager. Everything is Bash, organized into top-level directories by domain (`java/`, `database/`, `docker/`, `network/`, `security/`, `ai/`, etc.). Scripts target both Linux (CentOS/Ubuntu/Debian/Rocky/Alma/RHEL) and macOS, and must stay compatible with Bash 3.2+ (macOS ships 3.2).

Documentation and user-facing strings are written in Chinese. Match that convention when editing existing scripts.

## Common Commands

There is no central build system, package manifest, or test runner. Scripts are run directly:

```bash
bash <category>/<script>.sh           # run a script
bash java/jdk/install-jdk17.sh        # e.g. install JDK 17
bash java/jdk/switch-java.sh --version 11
```

Linting uses shellcheck (install via `security/code-security/install-shellcheck.sh`):

```bash
shellcheck path/to/script.sh
```

Cross-host sync (sky → star machines, auto-detects direction by user/hostname):

```bash
bash sync_and_run.sh
```

There is no automated test suite. Validate changes by running scripts in a disposable environment; the project convention is to verify compatibility on both CentOS and Ubuntu.

## AI Hub (`ai/`)

The most substantial subsystem. `ai/ai-hub.sh` is an interactive lifecycle manager for AI tools (CLI clients, agents, native IDEs, gateways, inference runtimes) plus MCP servers and Skills.

Architecture (control plane vs implementation plane):

- `ai/ai-hub.sh` — main entry point. Sources `ai/lib/loader.sh`.
- `ai/lib/` — core framework. `loader.sh` sources modules in a fixed order (`utils.sh` must load first since it provides logging; then `assoc.sh`, `json.sh`, `proxy.sh`, `cache.sh`, `config.sh`, `config-defaults.sh`, `tools.sh`, `system.sh`, `chrome.sh`, `menu.sh`). When adding a module, register it in `loader.sh`.
- `ai/conf/` — control plane (data only). Tool metadata under `conf/tools/{cli,ide,agent,gateway,runtime,...}/<tool>.json`; shared config under `conf/shared/mcp-servers/` and `conf/shared/skills/`; `conf/global.json` is the root config.
- `ai/agent/`, `ai/gateway/`, `ai/ide/`, `ai/runtime/` — implementation plane. Each tool's own scripts, templates, and runtime resources live in its category directory, not in `scripts/`.

Tools are declarative: a tool is defined by a JSON file (see `conf/tools/cli/antigravity.json` for the shape — `id`, `install.methods[]` with `command`/`check`/`uninstall`, `update`, `config.operations`). To add a tool, add its metadata JSON to the right `conf/tools/<category>/` dir and put implementation scripts under the matching `agent/`/`gateway/`/`ide/`/`runtime/` dir. Bash 3.2 lacks associative arrays, so the code guards them behind `_USE_ASSOC_ARRAY` (see `ai/lib/assoc.sh`).

`ai/lib/utils.sh` is the shared utility layer: logging (`info_log`/`warn_log`/`error_log`/`debug_log`/`success_log`/`success_msg`), safe execution (`run_with_timeout`), predicates (`command_exists`, `file_exists`), path/time helpers (`expand_path`, `get_timestamp`), and exit cleanup (`cleanup`, `handle_interrupt`, `_init_temp_files`). Reuse these rather than reimplementing.

## Script Conventions

Standard structure for middleware/tool directories:

```
<name>/
├── install-<name>.sh / uninstall-<name>.sh
├── config-<name>.sh / start-<name>.sh / stop-<name>.sh / status-<name>.sh
├── backup-<name>.sh / restore-<name>.sh / upgrade-<name>.sh
├── monitor-<name>.sh / health-<name>.sh
├── conf/      # config templates
├── docker/    # Dockerfile, docker-compose.yml
└── README.md
```

Required patterns (see `readme.md` "脚本编写规范" for the full spec):

- Header comment block with Script Name / Description / Author / Date / Version.
- `set -euo pipefail` plus an `error_exit` helper and `trap '...' ERR`.
- Timestamped logging: `log_info`/`log_warn`/`log_error`/`log_debug` (debug gated by `DEBUG=1`).
- Standard checks: `check_root`, `check_os`, `check_port` before acting.
- Idempotency, rollback on failure, version pinning for key components, and a post-install health check.
- Resolve the script's own dir via `BASH_SOURCE` (and follow symlinks where needed — see `git/giter.sh` `resolve_script_path`) rather than assuming `pwd`.

Install modes a script may support: `binary`, `package`, `source`, `docker`, `docker-compose`, `k8s`, `helm`, `standalone`.

## Naming & Commits

- Directories: lowercase kebab-case. Every tool dir must have a `README.md`.
- Scripts: `install-<name>.sh`, `uninstall-<name>.sh`, `config-<name>.sh`.
- Commit messages use Conventional Commits prefixes: `feat:`, `fix:`, `docs:`, `style:`, `refactor:`, `test:`, `chore:` (Chinese subject lines are common).

## Secrets

Never hardcode passwords or credentials. Read from environment variables with prompts as fallback, e.g. `DB_PASSWORD="${DB_PASSWORD:-...}"`. Set restrictive file permissions on generated config (`chmod 600`). Create temp files with `mktemp` and clean them up via `trap ... EXIT`.
