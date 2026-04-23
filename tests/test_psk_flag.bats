#!/usr/bin/env bats
# Tests for --psk flag / CLIENT_PSK env contract (v5.11.1 Phase C).
#
# Covers:
#   - render_client_config writes PresharedKey to the client [Peer] only
#     when CLIENT_PSK is set and non-empty.
#   - add_peer_to_server writes PresharedKey to the server [Peer] under
#     the same condition.
#   - generate_client resolves CLIENT_PSK="auto" via `awg genpsk`.
#   - manage_amneziawg.sh parses `--psk` flag and sets CLIENT_PSK="auto".

load test_helper

mock_awg() {
    # shellcheck disable=SC2317
    awg() {
        case "$1" in
            pubkey)  local _pk; _pk=$(cat); echo "pub_${_pk:0:20}" ;;
            genpsk)  echo "GENERATED_PSK_VALUE_32B==" ;;
            *)       command awg "$@" ;;
        esac
    }
    export -f awg
}

setup_params() {
    mock_awg
    create_server_config
    create_init_config
    # Minimal keys dir + server keys so generate_client path works
    mkdir -p "$KEYS_DIR"
    echo "SERVER_PRIV" > "$AWG_DIR/server_private.key"
    echo "SERVER_PUB"  > "$AWG_DIR/server_public.key"
}

@test "render_client_config: no PresharedKey when CLIENT_PSK unset" {
    setup_params
    unset CLIENT_PSK
    run render_client_config "noclient" "10.9.9.5" "CLIENT_PRIV" "SERVER_PUB" "1.2.3.4" "39743"
    [ "$status" -eq 0 ]
    [ -f "$AWG_DIR/noclient.conf" ]
    run grep -c '^PresharedKey = ' "$AWG_DIR/noclient.conf"
    [ "$output" = "0" ]
}

@test "render_client_config: writes PresharedKey when CLIENT_PSK set" {
    setup_params
    export CLIENT_PSK="USER_PROVIDED_PSK_32B=="
    run render_client_config "withpsk" "10.9.9.6" "CLIENT_PRIV" "SERVER_PUB" "1.2.3.4" "39743"
    [ "$status" -eq 0 ]
    [ -f "$AWG_DIR/withpsk.conf" ]
    run grep -c '^PresharedKey = USER_PROVIDED_PSK_32B==$' "$AWG_DIR/withpsk.conf"
    [ "$output" = "1" ]
    # PresharedKey must be inside [Peer], after PublicKey, before Endpoint
    run awk '/^\[Peer\]/{peer=1; next} peer && /^PublicKey/{pk=NR} peer && /^PresharedKey/{psk=NR} peer && /^Endpoint/{ep=NR} END{print pk, psk, ep}' "$AWG_DIR/withpsk.conf"
    read -r pk_line psk_line ep_line <<< "$output"
    [ "$pk_line" -lt "$psk_line" ]
    [ "$psk_line" -lt "$ep_line" ]
    unset CLIENT_PSK
}

@test "add_peer_to_server: no PresharedKey in server [Peer] when CLIENT_PSK unset" {
    setup_params
    unset CLIENT_PSK
    run add_peer_to_server "serverpeer_a" "CLIENT_PUB_A" "10.9.9.10"
    [ "$status" -eq 0 ]
    run grep -c 'PresharedKey' "$SERVER_CONF_FILE"
    [ "$output" = "0" ]
}

@test "add_peer_to_server: writes PresharedKey to server [Peer] when CLIENT_PSK set" {
    setup_params
    export CLIENT_PSK="PAIR_PSK_32B_SERVER_SIDE=="
    run add_peer_to_server "serverpeer_b" "CLIENT_PUB_B" "10.9.9.11"
    [ "$status" -eq 0 ]
    run grep -c '^PresharedKey = PAIR_PSK_32B_SERVER_SIDE==$' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
    # In [Peer] for serverpeer_b: AllowedIPs should still be present
    run grep -c '^AllowedIPs = 10\.9\.9\.11/32$' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
    unset CLIENT_PSK
}

@test "generate_client with CLIENT_PSK='auto' resolves to awg genpsk output" {
    setup_params
    export CLIENT_PSK="auto"
    # Need flock available — skip if not Linux
    require_flock
    # get_next_client_ip, add_peer_to_server, render_client_config all invoked.
    # We need a mock for get_server_public_ip too — otherwise it hits real net.
    # shellcheck disable=SC2317
    get_server_public_ip() { echo "203.0.113.1"; return 0; }
    export -f get_server_public_ip

    run generate_client "autopsk_client"
    [ "$status" -eq 0 ]
    [ -f "$AWG_DIR/autopsk_client.conf" ]
    # Both server and client should have the stub's generated PSK
    grep -q '^PresharedKey = GENERATED_PSK_VALUE_32B==$' "$AWG_DIR/autopsk_client.conf"
    grep -q '^PresharedKey = GENERATED_PSK_VALUE_32B==$' "$SERVER_CONF_FILE"
    unset CLIENT_PSK
}

@test "manage_amneziawg.sh parses --psk flag" {
    local MANAGE_RU="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
    local MANAGE_EN="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"
    grep -qE 'CLI_ADD_PSK=1' "$MANAGE_RU"
    grep -qE 'CLI_ADD_PSK=1' "$MANAGE_EN"
    grep -qE 'export CLIENT_PSK="auto"' "$MANAGE_RU"
    grep -qE 'export CLIENT_PSK="auto"' "$MANAGE_EN"
}

@test "manage help mentions --psk" {
    local MANAGE_RU="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
    local MANAGE_EN="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"
    grep -qE '\-\-psk' "$MANAGE_RU"
    grep -qE '\-\-psk' "$MANAGE_EN"
}
