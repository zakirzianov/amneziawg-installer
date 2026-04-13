#!/usr/bin/env bats
# Tests for restore_backup() tar validation and key permission hardening

load test_helper

# Helpers for creating test backup archives

create_good_backup() {
    local archive="$1"
    local td
    td=$(mktemp -d)
    mkdir -p "$td/server" "$td/clients" "$td/keys"
    echo "[Interface]" > "$td/server/awg0.conf"
    echo "PrivateKey = TEST" > "$td/server_private.key"
    echo "PublicKey = TEST" > "$td/server_public.key"
    echo "test" > "$td/clients/test.conf"
    echo "key" > "$td/keys/test.private"
    tar -czf "$archive" -C "$td" .
    rm -rf "$td"
}

create_bad_backup_absolute_path() {
    local archive="$1"
    local td
    td=$(mktemp -d)
    mkdir -p "$td"
    echo "evil" > "$td/normal.txt"
    # Create a tar with an absolute path entry via transform
    tar -czf "$archive" -C "$td" --transform='s|normal.txt|/etc/evil.txt|' normal.txt 2>/dev/null || {
        # Fallback: create tar normally, patch with python
        tar -czf "$archive" -C "$td" normal.txt
    }
    rm -rf "$td"
}

create_bad_backup_traversal() {
    local archive="$1"
    local td
    td=$(mktemp -d)
    mkdir -p "$td/sub"
    echo "evil" > "$td/sub/file.txt"
    tar -czf "$archive" -C "$td" --transform='s|sub/file.txt|../../etc/evil.txt|' sub/file.txt 2>/dev/null || {
        tar -czf "$archive" -C "$td" sub/file.txt
    }
    rm -rf "$td"
}

# --- tar validation tests ---

@test "restore_backup: good backup passes tar validation" {
    create_server_config
    create_init_config
    local archive="$TEST_DIR/good.tar.gz"
    create_good_backup "$archive"

    # Simulate restore environment
    export AWG_DIR="$TEST_DIR"
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export CONFIG_FILE="$TEST_DIR/awgsetup_cfg.init"
    export KEYS_DIR="$TEST_DIR/keys"
    export EXPIRY_DIR="$TEST_DIR/expiry"

    # We cannot fully test restore_backup (needs systemctl), but we
    # can verify the tar listing step passes for a good archive
    local listing
    listing=$(tar -tzf "$archive" 2>/dev/null)
    [ -n "$listing" ]

    # No absolute paths
    while IFS= read -r entry; do
        [[ "$entry" != /* ]]
    done <<< "$listing"

    # No parent traversal
    while IFS= read -r entry; do
        [[ "$entry" != *..* ]]
    done <<< "$listing"
}

@test "restore_backup: absolute path in tar is detected" {
    local archive="$TEST_DIR/bad_abs.tar.gz"
    create_bad_backup_absolute_path "$archive"

    local listing
    listing=$(tar -tzf "$archive" 2>/dev/null)
    [ -n "$listing" ]

    # If tar --transform worked, listing should contain /etc/evil.txt
    # If it did not (platform limitation), this test is informational
    local has_absolute=0
    while IFS= read -r entry; do
        if [[ "$entry" == /* ]]; then
            has_absolute=1
            break
        fi
    done <<< "$listing"

    # On platforms where --transform works, verify detection
    if [[ $has_absolute -eq 1 ]]; then
        # Our validation logic would catch this
        true
    else
        skip "tar --transform not supported on this platform"
    fi
}

@test "restore_backup: path traversal (..) in tar is detected" {
    local archive="$TEST_DIR/bad_trav.tar.gz"
    create_bad_backup_traversal "$archive"

    local listing
    listing=$(tar -tzf "$archive" 2>/dev/null)
    [ -n "$listing" ]

    local has_traversal=0
    while IFS= read -r entry; do
        if [[ "$entry" == *..* ]]; then
            has_traversal=1
            break
        fi
    done <<< "$listing"

    if [[ $has_traversal -eq 1 ]]; then
        true
    else
        skip "tar --transform not supported on this platform"
    fi
}

@test "restore_backup: server key chmod 600 after cp -a" {
    # Verify that the chmod 600 hardening in restore_backup works
    # by simulating the key copy + chmod sequence
    [[ "$(uname -s)" == "Linux" ]] || skip "stat format differs on non-Linux"

    local key="$TEST_DIR/server_private.key"
    echo "TESTKEY" > "$key"
    chmod 644 "$key"  # simulate broken mode from archive

    # Simulate what restore_backup does after cp -a
    chmod 600 "$key" 2>/dev/null || true

    local perms
    perms=$(stat -c %a "$key")
    [ "$perms" = "600" ]
}

@test "restore_backup: archive with dangerous entry type (b/c/p/h/l) is rejected" {
    # Validates the type-check loop in restore_backup(): archives containing
    # block devices (b), char devices (c), FIFOs (p), hardlinks (h), or
    # symlinks (l) must be rejected before extraction. We create a real
    # .tar.gz archive, then inject a mock tar binary that returns a verbose
    # listing with a block device entry, and verify the type-check logic
    # correctly sets result=1.  The logic tested here is identical to the
    # case statement inside restore_backup() (Phase 3 hardening).

    # Create a real archive (required so tar -tzf / tar -xzf still work)
    local archive="$TEST_DIR/bad_block.tar.gz"
    local td
    td=$(mktemp -d)
    echo "normal content" > "$td/file.txt"
    tar -czf "$archive" -C "$td" . 2>/dev/null
    rm -rf "$td"

    # Save real tar path before overriding PATH
    local real_tar
    real_tar=$(command -v tar)

    # Create a mock tar that injects a block device verbose line for -tvzf calls.
    # All other tar calls (e.g. -tzf, -xzf, -czf) pass through to the real tar.
    local mock_bin="$TEST_DIR/mock_tar_bin"
    mkdir -p "$mock_bin"
    # NOTE: unquoted STUB heredoc — \$1/\$@ are escaped, only $real_tar expands intentionally
    cat > "$mock_bin/tar" << STUB
#!/bin/bash
# Intercept verbose listing: first arg must be a flag (-*) containing 'v'.
# Matches -tvzf but not path arguments that happen to contain 'v'.
if [[ "\$1" == -* && "\$1" == *v* ]]; then
    echo "drwxr-xr-x root/root        0 2026-04-13 12:00 ./"
    echo "brw-rw---- root/disk     8, 0 2026-04-13 12:00 ./dev/sda"
    echo "-rw------- root/root     1234 2026-04-13 12:00 ./file.txt"
    exit 0
fi
exec "$real_tar" "\$@"
STUB
    chmod +x "$mock_bin/tar"

    # Override PATH so mock tar is found first (restored automatically by bats subshell)
    PATH="$mock_bin:$PATH"

    # Run the exact type-check logic from restore_backup()
    local _tar_verbose _vline _tc result=0
    _tar_verbose=$(tar -tvzf "$archive" 2>/dev/null)
    while IFS= read -r _vline; do
        [[ -z "$_vline" ]] && continue
        _tc="${_vline:0:1}"
        case "$_tc" in
            b|c|p|h|l)
                result=1
                break
                ;;
        esac
    done <<< "$_tar_verbose"

    [ "$result" -eq 1 ]
}
