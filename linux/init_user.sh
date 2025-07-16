#!/bin/bash

AddSAUser() {
    groupadd -g 901 sa
    for user in user1 user2; do
        useradd -g sa -u 90${i} $user
        echo "${user}123456!@#$%^" | passwd $user --stdin
    done
    echo "%sa ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
}