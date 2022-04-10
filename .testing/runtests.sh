#!/usr/bin/env bash

[[ $1 == "--quiet" ]] && QUIET=true || QUIET=false

bold=$(tput bold)
normal=$(tput sgr0)

echo_err() { echo -e "\e[31m${bold}$@${normal}\e[0m" >&2; }

process_output() {
    while read output; do
        if [[ "$output" =~ ^::error ]]; then
            echo_err $output
        elif [[ $QUIET == false ]]; then
            echo $output
        fi
    done
}

GITHUB_WORKSPACE=.

. .github/scripts/test.sh | process_output
exit ${PIPESTATUS[0]}