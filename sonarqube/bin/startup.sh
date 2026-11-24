#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

start_docker() {
    if [ "$(uname -s)" = "Linux" ]; then
        sysctl -w vm.max_map_count=524288 >/dev/null || true
        sysctl -w fs.file-max=131072 >/dev/null || true
        ulimit -n 131072 || true
        ulimit -u 8192 || true
    fi

    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        [[ "$dir" == ./* ]] && dir="$BASE_DIR/${dir#./}"
        if [ ! -f "$dir" ] && [ ! -d "$dir" ]; then
            echo "mkdir $dir"
            mkdir -p "$dir"
            chmod -R 777 "$dir" || true
        fi
    done < <(grep -A 100 'volumes:' "$BASE_DIR/docker-compose.yml" | grep -E '^[[:space:]]*-[[:space:]]*(\.|/)' | awk '{print $2}' | awk -F':' '{print $1}')

    if compose_cmd ps | grep -v NAME | grep -q running; then
        if [ "${1:-}" = "-f" ]; then
            compose_cmd down
        else
            echo "has been started!"
            compose_cmd ps
            exit 1
        fi
    fi

    compose_cmd up -d
    compose_cmd ps -a
}

start_host() {
    setup_java_home

    if pgrep -f "org.sonar.server.app.WebServer" >/dev/null 2>&1; then
        echo "SonarQube 已在运行"
        exit 0
    fi

    if [ "$(uname -s)" = "Darwin" ] && [ -x "$BASE_DIR/bin/macosx-universal-64/sonar.sh" ]; then
        "$BASE_DIR/bin/macosx-universal-64/sonar.sh" start
    elif [ -x "$BASE_DIR/bin/linux-x86-64/sonar.sh" ]; then
        "$BASE_DIR/bin/linux-x86-64/sonar.sh" start
    elif [ -x "$BASE_DIR/bin/sonar.sh" ]; then
        "$BASE_DIR/bin/sonar.sh" start
    else
        echo "找不到 SonarQube 启动脚本" >&2
        exit 1
    fi
}

if [ -f "$BASE_DIR/docker-compose.yml" ]; then
    start_docker "$@"
else
    start_host "$@"
fi
