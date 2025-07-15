#!/bin/bash

configure_audit_rules() {
    local rules_file="/etc/audit/audit.rules"
    local temp_rules_file=$(mktemp)

    cat << EOF > "$temp_rules_file"
-D
-b 8192
-m 2

-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k logins
-w /etc/security/opasswd -p wa -k logins
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k sudolog
EOF

    sort -u "$rules_file" "$temp_rules_file" -o "$temp_rules_file"
    mv "$temp_rules_file" "$rules_file"

    augenrules --load
}