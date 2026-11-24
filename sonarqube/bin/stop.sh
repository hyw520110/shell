#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
BASE_DIR="${CURRENT_DIR%/*}"
cd "$BASE_DIR"

setup_java_home() {
    if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
        export PATH="$JAVA_HOME/bin:$PATH"
        return 0
    fi

    local candidate
    for candidate in \
        "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home" \
        "/usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home" \
        "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home" \
        "/usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home"; do
        if [ -x "$candidate/bin/java" ]; then
            export JAVA_HOME="$candidate"
            export PATH="$JAVA_HOME/bin:$PATH"
            return 0
        fi
    done
}

compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    else
        docker compose "$@"
    fi
}

stop_docker() {
    if compose_cmd ps | grep -v NAME | grep -q running; then
        compose_cmd stop
    fi
    if [ "${1:-}" = "-f" ]; then
        compose_cmd down
    fi
}

stop_host() {
    setup_java_home

    if [ "$(uname -s)" = "Darwin" ] && [ -x "$BASE_DIR/bin/macosx-universal-64/sonar.sh" ]; then
        "$BASE_DIR/bin/macosx-universal-64/sonar.sh" stop || true
    elif [ -x "$BASE_DIR/bin/linux-x86-64/sonar.sh" ]; then
        "$BASE_DIR/bin/linux-x86-64/sonar.sh" stop || true
    elif [ -x "$BASE_DIR/bin/sonar.sh" ]; then
        "$BASE_DIR/bin/sonar.sh" stop || true
    fi
}

if [ -f "$BASE_DIR/docker-compose.yml" ]; then
    stop_docker "$@"
else
    stop_host "$@"
fi
