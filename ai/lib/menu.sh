#!/bin/bash
# ==================== 交互式菜单模块 ====================
# 提供方向键选择的交互式菜单功能
# 兼容 Bash 3.2+

menu_strip_ansi() {
    printf "%b" "$1" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g'
}

menu_display_width() {
    local s="$1"
    local w=0
    local i ch bytes
    for ((i=0; i<${#s}; i++)); do
        ch="${s:i:1}"
        bytes="$(LC_ALL=C printf "%s" "$ch" | od -An -tx1 | tr -d ' \n')"
        # Unicode variation selectors and zero-width joiner do not advance the cursor.
        # Common emoji sequences such as "⌨️" include FE0F; counting it as width 2
        # shifts the next grid column left/right on macOS Terminal/iTerm.
        case "$bytes" in
            efb88e|efb88f|e2808d)
                continue
                ;;
        esac
        if [[ "$(LC_ALL=C printf "%s" "$ch" | wc -c | tr -d ' ')" -eq 1 ]]; then
            ((w++))
        else
            ((w+=2))
        fi
    done
    echo "$w"
}

menu_truncate_display() {
    local s="$1"
    local max="$2"
    local out=""
    local w=0
    local i ch cw bytes
    [[ "$max" -le 0 ]] && { echo ""; return; }
    for ((i=0; i<${#s}; i++)); do
        ch="${s:i:1}"
        bytes="$(LC_ALL=C printf "%s" "$ch" | od -An -tx1 | tr -d ' \n')"
        case "$bytes" in
            efb88e|efb88f|e2808d)
                cw=0
                ;;
            *)
                if [[ "$(LC_ALL=C printf "%s" "$ch" | wc -c | tr -d ' ')" -eq 1 ]]; then
                    cw=1
                else
                    cw=2
                fi
                ;;
        esac
        if [[ $((w + cw)) -gt "$max" ]]; then
            break
        fi
        out+="$ch"
        w=$((w + cw))
    done
    if [[ "$out" != "$s" && "$max" -ge 3 ]]; then
        while [[ $(menu_display_width "$out") -gt $((max - 3)) ]]; do
            out="${out%?}"
        done
        out+="..."
    fi
    echo "$out"
}

menu_pad_display() {
    local s="$1"
    local width="$2"
    local pad=$((width - $(menu_display_width "$s")))
    [[ $pad -lt 0 ]] && pad=0
    printf "%s%*s" "$s" "$pad" ""
}

# 方向键选择菜单函数 (增强版 - 支持 Tabs、预选、数字快速跳转和首字母定位)
# 参数: prompt, multi_select, allow_exit, preselected, tabs_var, current_tab_var, options_array
menu_select() {
    local parent_tty
    parent_tty=$(stty -g 2>/dev/null || echo "")
    
    local res
    res=$(_menu_select_impl "$@")
    
    if [[ -n "$parent_tty" ]]; then
        stty "$parent_tty" 2>/dev/null || true
    else
        stty echo icanon 2>/dev/null || true
    fi
    printf "\033[?25h" >&2
    
    echo "$res"
}

_menu_select_impl() {
    local prompt="$1"
    local multi="$2"
    local allow_exit="$3"
    local preselected="$4"
    local tabs_var="$5"
    local current_tab_var="$6"
    shift 6
    local options=("$@")
    
    local count=${#options[@]}
    local selected=()
    local i

    # 解析 Tabs
    local -a tabs=()
    local cur_tab=0
    if [[ -n "$tabs_var" ]]; then
        if [[ "$tabs_var" == "TABS" ]]; then tabs=("${TABS[@]}"); else eval "tabs=(\"\${$tabs_var[@]}\")"; fi
    fi
    if [[ -n "$current_tab_var" ]]; then
        eval "cur_tab=\${$current_tab_var}"
    fi
    local tab_count=${#tabs[@]}

    # 初始化选中状态：先用 preselected（推荐预选），再用恢复状态（tab 切换记忆）
    for ((i=0; i<count; i++)); do
        selected[i]=false
    done
    for ps in $preselected; do
        [[ "$ps" =~ ^[0-9]+$ && $ps -lt $count ]] && selected[$ps]=true
    done
    if [[ -n "${_MENU_RESTORE_INDICES:-}" ]]; then
        for _ri in $_MENU_RESTORE_INDICES; do
            [[ "$_ri" =~ ^[0-9]+$ && $_ri -lt $count ]] && selected[$_ri]=true
        done
        _MENU_RESTORE_INDICES=""
    fi
    local cur="${_MENU_RESTORE_CURSOR:-0}"
    _MENU_RESTORE_CURSOR=""

    local is_interactive=false
    [[ -t 0 ]] && is_interactive=true
    if [[ "$is_interactive" != "true" ]]; then
        echo "EXIT"
        return 0
    fi

    local original_tty_settings=""
    original_tty_settings=$(stty -g 2>/dev/null || echo "")
    stty -echo -icanon min 1 time 0 2>/dev/null || true
    printf "\033[?25l" >&2
    # 清空输入缓冲区（纯 Bash 兼容实现，支持 macOS Bash 3.2）
    while read -t 0 2>/dev/null; do read -r -t 1 discard 2>/dev/null || true; done

    # 备用屏幕缓冲区（主菜单用，消除空行残留和回滚干扰）
    local _alt_screen_active=false
    if [[ "${_MENU_ALT_SCREEN:-false}" == "true" ]]; then
        printf "\033[?1049h" >&2   # 进入备用屏幕
        sleep 0.05                 # 给终端一点时间切换，防止吞掉下一行（Tab Bar）
        _alt_screen_active=true
    fi
    local term_width="${_term_width:-$(tput cols 2>/dev/null || echo 80)}"
    _term_width="$term_width"

    local term_height
    if [[ -n "${LINES:-}" && "$LINES" =~ ^[0-9]+$ ]]; then
        term_height="$LINES"
    elif command -v stty >/dev/null 2>&1 && stty size >/dev/null 2>&1; then
        term_height=$(stty size | awk '{print $1}')
    else
        term_height=$(tput lines 2>/dev/null || echo 40)
    fi
    
    # 如果检测到的高度依然非常小（例如一些伪终端默认返回 24 或 10），我们设定一个更有用的安全底线
    # 假设用户的全屏窗口通常至少有 60 行以上（对于现代显示器）
    [[ -z "$term_height" || "$term_height" -lt 15 ]] && term_height=60
    local scroll_offset=0

    menu_first_list_index() {
        local _mi
        for ((_mi=0; _mi<count; _mi++)); do
            [[ "${options[$_mi]}" == @* ]] || { echo "$_mi"; return 0; }
        done
        echo 0
    }

    menu_last_list_index() {
        local _mi
        for ((_mi=count-1; _mi>=0; _mi--)); do
            [[ "${options[$_mi]}" == @* ]] || { echo "$_mi"; return 0; }
        done
        echo 0
    }

    menu_prev_list_index() {
        local _from="$1"
        local _mi
        for ((_mi=_from-1; _mi>=0; _mi--)); do
            [[ "${options[$_mi]}" == @* ]] || { echo "$_mi"; return 0; }
        done
        menu_last_list_index
    }

    menu_next_list_index() {
        local _from="$1"
        local _mi
        for ((_mi=_from+1; _mi<count; _mi++)); do
            [[ "${options[$_mi]}" == @* ]] || { echo "$_mi"; return 0; }
        done
        menu_first_list_index
    }

    # 渲染函数（固定头尾 + 中间可滚动视口）
    render_menu() {
        local start_line=$1
        local is_first=$2

        # ---- 计算布局 ----
        # 头部行数 (prompt/tabs 行 + hint 行)
        local head_h=2
        # 底部行数
        local foot_h=0
        local _foot_item_count=0
        for ((_fi=0; _fi<count; _fi++)); do
            [[ "${options[$_fi]}" == @* ]] && ((_foot_item_count++))
        done
        [[ "$allow_exit" == "true" ]] && ((_foot_item_count++))
        if [[ $_foot_item_count -gt 0 ]]; then
            foot_h=1
        else
            foot_h=0
        fi
        # ---- 构建列表项索引（非@项）----
        local -a _lidx=()
        for ((_li=0; _li<count; _li++)); do
            [[ "${options[$_li]}" == @* ]] || _lidx+=($_li)
        done
        local _lcnt=${#_lidx[@]}

        # 列表可用行数
        local list_h
        local available_h=$((term_height - head_h - foot_h))
        [[ $available_h -lt 3 ]] && available_h=3
        local _show_all_fits=false
        if [[ "${_MENU_SHOW_ALL:-false}" == "true" ]]; then
            if [[ $_lcnt -le $available_h ]]; then
                list_h=$_lcnt
                _show_all_fits=true
            else
                list_h=$available_h
            fi
            [[ $list_h -lt 3 ]] && list_h=3
        else
            list_h=$available_h
        fi

        # ---- 调整 scroll_offset 确保 cur 可见 ----
        if [[ "$_show_all_fits" == "true" ]]; then
            scroll_offset=0
        else
            if [[ "${options[$cur]}" != @* && $cur -ne $count ]]; then
                local _cpos=-1
                for ((_ci=0; _ci<_lcnt; _ci++)); do
                    [[ "${_lidx[$_ci]}" -eq "$cur" ]] && { _cpos=$_ci; break; }
                done
                
                # Check if _cpos is visible with current scroll_offset by simulating render
                while true; do
                    if [[ $_cpos -lt $scroll_offset ]]; then
                        scroll_offset=$_cpos
                        break
                    fi
                    
                    local _sim_lines=0
                    [[ $scroll_offset -gt 0 ]] && _sim_lines=1
                    local _sim_last_header=-1
                    local _sim_vi=$scroll_offset
                    local _is_visible=false
                    
                    while [[ $_sim_vi -lt $_lcnt ]]; do
                        if [[ $_sim_lines -ge $((list_h - 1)) && $_sim_vi -lt $((_lcnt - 1)) ]]; then
                            break
                        fi
                        
                        local _sim_i=${_lidx[$_sim_vi]}
                        local _sim_need_hdr=false
                        if [[ "${options[$_sim_i]}" != HEADER:* ]]; then
                            local _hi=$((_sim_i-1))
                            while [[ $_hi -ge 0 ]]; do
                                if [[ "${options[$_hi]}" == HEADER:* ]]; then
                                    [[ $_hi -ne $_sim_last_header ]] && _sim_need_hdr=true
                                    break
                                fi
                                ((_hi--))
                            done
                        fi
                        
                        if [[ "$_sim_need_hdr" == "true" ]]; then
                            if [[ $_sim_lines -ge $((list_h - 2)) && $_sim_vi -lt $((_lcnt - 1)) ]]; then
                                break
                            fi
                            ((_sim_lines++))
                            _sim_last_header=$_hi
                        fi
                        
                        if [[ "${options[$_sim_i]}" == HEADER:* ]]; then
                            _sim_last_header=$_sim_i
                        fi
                        
                        ((_sim_lines++))
                        
                        if [[ $_sim_vi -eq $_cpos ]]; then
                            _is_visible=true
                            break
                        fi
                        
                        ((_sim_vi++))
                    done
                    
                    if [[ "$_is_visible" == "true" ]]; then
                        break
                    else
                        ((scroll_offset++))
                    fi
                done
            fi
            [[ $scroll_offset -lt 0 ]] && scroll_offset=0
            [[ $scroll_offset -gt $((_lcnt - 1)) ]] && scroll_offset=$((_lcnt - 1))
            [[ $scroll_offset -lt 0 ]] && scroll_offset=0
        fi

        # ---- 计算可见范围（含指示器）----
        local _top_ind=0
        [[ "$_show_all_fits" != "true" && $scroll_offset -gt 0 ]] && _top_ind=1
        local _avail1=$((list_h - _top_ind))
        local _vend1=$((scroll_offset + _avail1))
        [[ $_vend1 -gt $_lcnt ]] && _vend1=$_lcnt
        local _bot_ind=0
        [[ "$_show_all_fits" != "true" && $_vend1 -lt $_lcnt ]] && _bot_ind=1
        local _avail2=$((list_h - _top_ind - _bot_ind))
        local _vend=$((scroll_offset + _avail2))
        [[ $_vend -gt $_lcnt ]] && _vend=$_lcnt

        # ---- 清屏 ----
        if [[ "$is_first" == "true" ]]; then
            if [[ "$_alt_screen_active" == "true" ]]; then
                command -v clear >/dev/null 2>&1 && clear >&2 || printf "\033[2J\033[H" >&2
            else
                printf "\033[J" >&2
            fi
        else
            printf "\r\033[%dA" "$start_line" >&2
        fi
        printf "\033[J" >&2
        local _lines_printed=0

        # ==== 1. 头部：Inline Tabs & Prompt ====
        if [[ $tab_count -gt 0 ]]; then
            local base_prompt="${prompt%% (*}"
            local header_str="${CYAN}${base_prompt}: ${NC}"
            for ((t=0; t<tab_count; t++)); do
                if [[ $t -eq $cur_tab ]]; then
                    header_str+="${CYAN}[ ${tabs[$t]} ]${NC} "
                else
                    header_str+="${NC} ${tabs[$t]}  ${NC}"
                fi
            done
            # 强制追加一个换行并多打一个空格，防止行首被奇怪的终端吞噬
            printf " %b\n" "${header_str}" >&2
        else
            printf " %b\n" "${CYAN}${prompt:-[DEBUG: TABS EMPTY]}${NC}" >&2
        fi
        ((_lines_printed++))
        local hint
        if [[ "$multi" == "true" ]]; then
            hint="(↑↓移动，←→切换，数字跳转，字母定位，空格勾选，回车确认"
        else
            hint="(↑↓移动，←→切换，数字跳转，字母定位，空格/回车确认"
        fi
        [[ "$allow_exit" == "true" ]] && hint="${hint}，q 退出"
        hint="${hint})"
        printf "\r%b\n" "${YELLOW}${hint}${NC}" >&2
        _lines_printed=$((_lines_printed + 1))

        # ---- 计算显示编号 ----
        local -a _dnum=()
        local _dn=0
        for ((_di=0; _di<count; _di++)); do
            if [[ "${options[$_di]}" == HEADER:* || "${options[$_di]}" == @* ]]; then
                _dnum[$_di]=0
            else
                ((_dn++))
                _dnum[$_di]=$_dn
            fi
        done
        local max_len=$((term_width - 15))
        local _list_printed=0

        local _show_all_grid=false

        # ==== 2. 顶部滚动提示 ====
        if [[ "$_show_all_grid" != "true" ]]; then
            if [[ $_top_ind -eq 1 ]]; then
                printf "\r%b\n" "${GRAY}  ↑ 向上还有 ${scroll_offset} 项${NC}" >&2
                ((_lines_printed++))
                ((_list_printed++))
            fi

            # ==== 3. 渲染可见列表项 ====
            local _last_header=-1
            local in_header=false
            local _vi=$scroll_offset
            local _has_more_below=false

            while [[ $_vi -lt $_lcnt ]]; do
            # 预留最后一行给“向下提示”
            if [[ "$_show_all_fits" != "true" && $_list_printed -ge $((list_h - 1)) && $_vi -lt $((_lcnt - 1)) ]]; then
                _has_more_below=true
                break
            fi

            local i=${_lidx[$_vi]}
            local line="${options[$i]}"

            # 检查是否需要插入前置 HEADER
            local _need_hdr=false
            local _hi=-1
            if [[ "$line" != HEADER:* ]]; then
                _hi=$((i-1))
                while [[ $_hi -ge 0 ]]; do
                    if [[ "${options[$_hi]}" == HEADER:* ]]; then
                        if [[ $_hi -ne $_last_header ]]; then
                            _need_hdr=true
                        fi
                        break
                    fi
                    ((_hi--))
                done
            fi

            # 插入前置 Header
            if [[ "$_need_hdr" == "true" ]]; then
                # 如果插入 header 和 item 会超过空间，提前 break
                if [[ "$_show_all_fits" != "true" && $_list_printed -ge $((list_h - 2)) && $_vi -lt $((_lcnt - 1)) ]]; then
                    _has_more_below=true
                    break
                fi

                local _hdr="${options[$_hi]:7}"
                _hdr="${_hdr//$'\n'/ }"
                [[ $max_len -gt 10 && ${#_hdr} -gt $max_len ]] && _hdr="${_hdr:0:$max_len}..."
                local _hdr_cb="[ ]"
                [[ "${selected[$_hi]}" == "true" ]] && _hdr_cb="[x]"
                if [[ $_hi -eq $cur ]]; then
                    printf "\r%b\n" "${BLUE}> ${_hdr_cb} ${BOLD}${CYAN}${_hdr}${NC}" >&2
                else
                    printf "\r%b\n" "  ${_hdr_cb} ${BOLD}${_hdr}${NC}" >&2
                fi
                ((_lines_printed++))
                ((_list_printed++))
                _last_header=$_hi
                in_header=true
            elif [[ "$line" == HEADER:* ]]; then
                in_header=true
            fi

            # 渲染当前项
            local is_special=false
            local is_header=false
            local display_line="$line"
            local label=""

            if [[ "$line" == HEADER:* ]]; then
                is_header=true
                display_line="${line:7}"
            fi

            display_line="${display_line//$'\n'/ }"
            [[ $max_len -gt 10 && ${#display_line} -gt $max_len ]] && display_line="${display_line:0:$max_len}..."

            local prefix="  "
            [[ $i -eq $cur ]] && prefix="${BLUE}> "

            if [[ "$is_header" == "true" ]]; then
                local checkbox="[ ]"
                [[ "${selected[$i]}" == "true" ]] && checkbox="[x]"
                if [[ $i -eq $cur ]]; then
                    printf "\r%b\n" "${prefix}${checkbox} ${BOLD}${CYAN}${display_line}${NC}" >&2
                else
                    printf "\r%b\n" "${prefix}${checkbox} ${BOLD}${display_line}${NC}" >&2
                fi
                _last_header=$i
            else
                local num=${_dnum[$i]}
                local indent=""
                [[ "$in_header" == "true" ]] && indent="  "

                if [[ "$multi" == "true" ]]; then
                    local checkbox="[ ]"
                    [[ "${selected[$i]}" == "true" ]] && checkbox="[x]"
                    if [[ $i -eq $cur ]]; then
                        printf "\r%b\n" "${prefix}${indent}${checkbox} ${num}. ${CYAN}${display_line}${NC}" >&2
                    else
                        printf "\r%b\n" "${prefix}${indent}${checkbox} ${num}. ${display_line}" >&2
                    fi
                else
                    if [[ $i -eq $cur ]]; then
                        printf "\r%b\n" "${prefix}${indent}${num}. ${CYAN}${display_line}${NC}" >&2
                    else
                        printf "\r%b\n" "${prefix}${indent}${num}. ${display_line}" >&2
                    fi
                fi
            fi
            ((_lines_printed++))
            ((_list_printed++))
                ((_vi++))
            done

            # ==== 4. 底部滚动提示 ====
            if [[ "$_has_more_below" == "true" ]]; then
                printf "\r%b\n" "${GRAY}  ↓ 向下还有 $((_lcnt - _vi)) 项${NC}" >&2
                ((_lines_printed++))
                ((_list_printed++))
            fi
        fi

        # ==== 5. 填充空行（保持底部对齐）====
        if [[ "$_alt_screen_active" == "true" ]]; then
            while [[ "$_show_all_fits" != "true" && $_list_printed -lt $list_h ]]; do
                printf "\r\n" >&2
                ((_lines_printed++))
                ((_list_printed++))
            done
        fi

        # ==== 6. 底部：操作栏 (@项) 和 退出选项 (横向) ====
        local -a foot_items=()
        for ((_fi=0; _fi<count; _fi++)); do
            [[ "${options[$_fi]}" == @* ]] && foot_items+=("$_fi")
        done
        [[ "$allow_exit" == "true" ]] && foot_items+=("$count")
        
        local f_row=""
        for _fidx in "${foot_items[@]}"; do
            local item_str=""
            if [[ $_fidx -eq $count ]]; then
                item_str="q. 退出"
            else
                local _fline="${options[$_fidx]}"
                item_str="${_fline:1:1}. ${_fline:3}"
                item_str="${item_str//$'\n'/ }"
            fi
            
            if [[ $_fidx -eq $cur ]]; then
                item_str="${BLUE}> ${CYAN}${item_str}${NC}"
            else
                item_str="  ${item_str}"
            fi
            
            f_row+="${item_str}   "
        done
        if [[ -n "$f_row" ]]; then
            printf "\r%b\n" "$f_row" >&2
            ((_lines_printed++))
        fi

        return $_lines_printed
    }

    local rendered_lines=0
    render_menu 0 true
    rendered_lines=$?

    while true; do
        if [[ "$is_interactive" == "true" ]]; then
            local key=""
            local char=""

            if ! IFS= read -rsn1 char; then break; fi
            key="$char"

            # 兼容 Bash 3.2 的 escape 序列读取逻辑
            if [[ "$char" == $'\x1b' ]]; then
                local old_stty_state=$(stty -g 2>/dev/null)
                # 设置 0.1 秒超时 (time 1)
                stty -icanon min 0 time 1 2>/dev/null || true
                local rest=""
                if IFS= read -rsn2 rest 2>/dev/null; then
                    key="${key}${rest}"
                fi
                [[ -n "$old_stty_state" ]] && stty "$old_stty_state" 2>/dev/null || true
            fi

            local old_cur=$cur
            local old_tab=$cur_tab
            local old_selected_state="${selected[*]}"

            case "$key" in
                $'\x1b[A'|$'\x1bOA'|k|p|P)
                    cur=$(menu_prev_list_index "$cur")
                    ;;
                $'\x1b[B'|$'\x1bOB'|j|n|N)
                    cur=$(menu_next_list_index "$cur")
                    ;;
                $'\x1b[D'|$'\x1bOD') # Left Arrow
                    if [[ $tab_count -gt 1 ]]; then
                        ((cur_tab--))
                        [[ $cur_tab -lt 0 ]] && cur_tab=$((tab_count - 1))
                        eval "$current_tab_var=\$cur_tab"
                        key="TAB_CHANGE"
                        break
                    fi
                    ;;
                $'\x1b[C'|$'\x1bOC') # Right Arrow
                    if [[ $tab_count -gt 1 ]]; then
                        ((cur_tab++))
                        [[ $cur_tab -ge $tab_count ]] && cur_tab=0
                        eval "$current_tab_var=\$cur_tab"
                        key="TAB_CHANGE"
                        break
                    fi
                    ;;
                " ")
                    if [[ "$multi" == "true" && $cur -lt $count && "${options[$cur]}" != @* ]]; then
                        local new_state=$([[ "${selected[$cur]}" == "true" ]] && echo "false" || echo "true")
                        selected[$cur]=$new_state
                        
                        # 如果是 Header，则执行批量选择逻辑
                        if [[ "${options[$cur]}" == HEADER:* ]]; then
                            local next=$((cur + 1))
                            while [[ $next -lt $count && "${options[$next]}" != HEADER:* && "${options[$next]}" != @* ]]; do
                                selected[$next]=$new_state
                                ((next++))
                            done
                        fi
                    elif [[ "$multi" != "true" ]]; then
                        break
                    fi
                    ;;
                "")
                    break
                    ;;
                "q"|"Q")
                    if [[ "$allow_exit" == "true" ]]; then
                         cur=$count; break
                    fi
                    ;;
                [0-9])
                    # (此处保留原有的数字跳转逻辑，略...)
                    local num_str="$key"
                    local next=""
                    local prompt_line=$((rendered_lines + 2))
                    printf "\r\033[${prompt_line}A\033[K${YELLOW}跳转至: ${num_str}_${NC}" >&2
                    
                    local bash_major="${BASH_VERSION%%.*}"
                    if [[ "$bash_major" -ge 4 ]]; then
                        while IFS= read -rsn1 -t 0.4 next 2>/dev/null; do
                            if [[ "$next" =~ [0-9] ]]; then
                                num_str="${num_str}${next}"
                                [[ $((10#$num_str)) -gt $count ]] && break
                                printf "\r\033[${prompt_line}A\033[K${YELLOW}跳转至: ${num_str}_${NC}" >&2
                            else break; fi
                        done
                    else
                        local old_tty=$(stty -g 2>/dev/null); stty -icanon min 0 time 4 2>/dev/null || true
                        while true; do
                            if ! IFS= read -rsn1 next 2>/dev/null; then break; fi
                            [[ -z "$next" ]] && break
                            if [[ "$next" =~ [0-9] ]]; then
                                num_str="${num_str}${next}"
                                [[ $((10#$num_str)) -gt $count ]] && break
                                printf "\r\033[${prompt_line}A\033[K${YELLOW}跳转至: ${num_str}_${NC}" >&2
                            else break; fi
                        done
                        [[ -n "$old_tty" ]] && stty "$old_tty" 2>/dev/null || true
                    fi
                    printf "\r\033[${prompt_line}A\033[K" >&2
                    # 按显示编号跳转（HEADER 不计入编号）
                    local target_num=$((10#$num_str))
                    local _j _jd=0
                    for ((_j=0; _j<count; _j++)); do
                        [[ "${options[$_j]}" == HEADER:* || "${options[$_j]}" == @* ]] && continue
                        ((_jd++))
                        if [[ $_jd -eq $target_num ]]; then
                            cur=$_j
                            break
                        fi
                    done
                    ;;
                [a-zA-Z])
                    # (此处保留原有的字母定位逻辑，略...)
                    local letter_low=$(echo "$key" | tr '[:upper:]' '[:lower:]')
                    local target_idx=""
                    for ((i=0; i<count; i++)); do
                        if [[ "${options[$i]}" == @* ]]; then
                            local key_char="${options[$i]:1:1}"
                            [[ "$letter_low" == "$(echo "$key_char" | tr '[:upper:]' '[:lower:]')" ]] && { target_idx=$i; cur=$i; break; }
                        fi
                    done
                    if [[ -z "$target_idx" ]]; then
                        local found=false
                        local line first_char
                        for ((i=cur; i<count; i++)); do
                            line="${options[$i]}"
                            [[ "$line" == @* ]] && continue
                            first_char=$(echo "$line" | sed 's/\x1b\[[0-9;]*m//g' | cut -c1)
                            if [[ "$(echo "$first_char" | tr '[:upper:]' '[:lower:]')" == "$letter_low" ]]; then
                                cur=$i; found=true; break
                            fi
                        done
                        if [[ "$found" == "false" ]]; then
                            for ((i=0; i<cur; i++)); do
                                line="${options[$i]}"
                                [[ "$line" == @* ]] && continue
                                first_char=$(echo "$line" | sed 's/\x1b\[[0-9;]*m//g' | cut -c1)
                                if [[ "$(echo "$first_char" | tr '[:upper:]' '[:lower:]')" == "$letter_low" ]]; then
                                    cur=$i; break
                                fi
                            done
                        fi
                    fi
                    ;;
            esac

            # 边界检查
            local max_idx=$count
            [[ "$allow_exit" == "true" ]] && ((max_idx++))
            if [[ $cur -lt 0 || $cur -ge $max_idx ]]; then cur=$(menu_first_list_index); fi

            # 渲染更新
            if [[ $cur -ne $old_cur || "$old_selected_state" != "${selected[*]}" ]]; then
                render_menu $rendered_lines false
                rendered_lines=$?
            fi
        else
            break
        fi
    done

    if [[ -n "$original_tty_settings" ]]; then stty "$original_tty_settings" 2>/dev/null || true; fi
    printf "\033[?25h" >&2

    if [[ "$key" == "TAB_CHANGE" ]]; then
        # Tab 切换：清屏备用屏幕内容（无需 2J，下次 render_menu 会处理）
        printf "\033[H\033[J" >&2
        # 将选中状态编码到输出中，供调用方解析（子 shell 无法传递全局变量）
        local _save_idxs=""
        for ((_si=0; _si<count; _si++)); do
            [[ "${selected[$_si]}" == "true" ]] && _save_idxs="${_save_idxs} ${_si}"
        done
        echo "TAB:${cur_tab}:${_save_idxs# }:${cur}"
    elif [[ "$cur" -eq "$count" && "$allow_exit" == "true" ]]; then
        echo "EXIT"
    else
        local results=()
        for ((i=0; i<count; i++)); do [[ "${selected[$i]}" == "true" ]] && results+=($i); done
        results+=($cur)
        echo "${results[@]}"
    fi

    # 退出备用屏幕（恢复用户之前的终端内容）
    if [[ "$_alt_screen_active" == "true" ]]; then
        if [[ "$key" != "TAB_CHANGE" ]]; then
            printf "\033[?1049l" >&2
        fi
    fi

    return 0
}
