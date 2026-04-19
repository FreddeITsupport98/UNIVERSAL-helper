#!/usr/bin/env bash

znh_regression_default_target_file() {
    local repo_root="${1:-}"
    local uni_path="${repo_root}/UNI-auto.sh"
    local legacy_path="${repo_root}/zypper-auto.sh"
    if [ -f "${uni_path}" ]; then
        printf '%s\n' "${uni_path}"
    else
        printf '%s\n' "${legacy_path}"
    fi
}

znh_regression_resolve_target_file() {
    local repo_root="${1:-}"
    local explicit_target="${2:-}"
    if [ -n "${explicit_target}" ]; then
        printf '%s\n' "${explicit_target}"
        return 0
    fi
    znh_regression_default_target_file "${repo_root}"
}
