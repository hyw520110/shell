# AI Hub 静态检查入口。
#   make check  只需要 bash + jq：脚本语法 + conf/ 下全部 JSON 可解析
#   make lint   需要 shellcheck，没装则提示并跳过（本机装不了：macOS 12 无 bottle，源码构建要 GHC）
# CI 上想让「没装 shellcheck」也算失败：make lint REQUIRE=1
# 想扩大范围：make check FILES="$(find . -name '*.sh')"

SHELL := /bin/bash
FILES    ?= ai-hub.sh $(wildcard lib/*.sh) $(wildcard scripts/*.sh)
JSONDIR  ?= conf
SEVERITY ?= warning
REQUIRE  ?= 0

.PHONY: check lint json syntax

check: syntax json

syntax:
	@rc=0; \
	for f in $(FILES); do \
		bash -n "$$f" || { echo "✗ 语法错误: $$f"; rc=1; }; \
	done; \
	if [ $$rc -ne 0 ]; then exit $$rc; fi; \
	echo "✓ bash -n 通过：$$(printf '%s\n' $(FILES) | wc -l | tr -d ' ') 个脚本"

json:
	@rc=0; n=0; \
	while IFS= read -r f; do \
		n=$$((n + 1)); \
		jq empty "$$f" >/dev/null 2>&1 || { echo "✗ JSON 解析失败: $$f"; rc=1; }; \
	done < <(find $(JSONDIR) -name '*.json' -not -name '.*'); \
	if [ $$rc -ne 0 ]; then exit $$rc; fi; \
	echo "✓ jq 校验通过：$$n 个配置"

lint:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "shellcheck 未安装，跳过（本机 macOS 12 属 brew Tier 3，只能源码构建 GHC，别指望 brew）"; \
		[ "$(REQUIRE)" = "1" ] && exit 1 || exit 0; \
	fi; \
	shellcheck -S $(SEVERITY) $(FILES) && echo "✓ shellcheck 通过（severity=$(SEVERITY)）"
