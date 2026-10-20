#!/usr/bin/env bash
set -Eeuo pipefail

# Test the terminal menu without running installation or removal commands.
command -v script >/dev/null || { echo 'The script utility is required' >&2; exit 1; }
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

# Exit immediately after selection to keep this test independent of GLPI.
sed '/^    select_operation$/a\    printf "MENU_MODE=%s\\n" "$MODE"; exit 0' \
    glpi-installer.sh > "$sandbox/installer.sh"

assert_choice() {
    local input=$1 expected=$2 output
    output=$(printf '%s\n' "$input" | script -q -e -c "bash '$sandbox/installer.sh'" /dev/null)
    if ! grep -Fq "MENU_MODE=$expected" <<< "$output"; then
        printf 'Selection %s did not choose %s:\n%s\n' "$input" "$expected" "$output" >&2
        exit 1
    fi
}

assert_choice 1 install
assert_choice 2 upgrade
assert_choice 3 uninstall
assert_choice $'invalid\n2' upgrade

cancelled=$(printf '0\n' | script -q -e -c "bash '$sandbox/installer.sh'" /dev/null)
grep -Fq 'Opération annulée.' <<< "$cancelled"
if grep -Fq 'MENU_MODE=' <<< "$cancelled"; then
    echo 'Exit option must not select an operation' >&2
    exit 1
fi

# A non-interactive invocation without flags must fail closed.
if bash "$sandbox/installer.sh" </dev/null >/dev/null 2>&1; then
    echo 'No-argument invocation without a terminal unexpectedly succeeded' >&2
    exit 1
fi

# Explicit CLI options bypass the menu.
if bash "$sandbox/installer.sh" --help | grep -q 'MENU_MODE='; then
    echo 'Explicit options unexpectedly opened the menu' >&2
    exit 1
fi

# Confirmations must be read from the controlling terminal, even when stdin
# supplies the installer source (as in curl | sudo bash).
sed '/^    select_operation$/a\    confirm_operation "Confirmer"; printf "CONFIRMED=%s\\n" "$MODE"; exit 0' \
    glpi-installer.sh > "$sandbox/confirm.sh"

confirmed=$(printf '2\no\n' | script -q -e -c "bash '$sandbox/confirm.sh'" /dev/null)
grep -Fq 'CONFIRMED=upgrade' <<< "$confirmed"

if printf '3\nn\n' | script -q -e -c "bash '$sandbox/confirm.sh'" /dev/null | grep -Fq 'CONFIRMED='; then
    echo 'A declined confirmation unexpectedly proceeded' >&2
    exit 1
fi

echo 'Interactive operation menu tests passed'
