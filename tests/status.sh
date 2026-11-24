#!/usr/bin/env bash
# Run status tests without a Proxmox host or a real Borg repository.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/vzborg-tests.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/config" "$work/ct" "$work/vm" "$work/tmp"
printf 'DEFAULT_KEEP="--keep-last=2"\nVZBORG_TEMP_DIR="%s/tmp"\nNOTIFY_TO="test@example.com"\n' "$work" >"$work/config/default"
printf 'name: guest101\n' >"$work/vm/101.conf"
printf 'hostname: guest102\n' >"$work/ct/102.conf"
printf 'name: guest103\n' >"$work/vm/103.conf"

# Substitute only hard-coded host paths in an isolated copy of the script.
python3 - "$root/vzborg" "$work" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
work = pathlib.Path(sys.argv[2])
source = source.replace('. /etc/vzborg/default', f'. "{work}/config/default"')
source = source.replace('ct_conf_dir="/etc/pve/nodes/$(hostname)/lxc/"', f'ct_conf_dir="{work}/ct/"')
source = source.replace('vm_conf_dir="/etc/pve/nodes/$(hostname)/qemu-server/"', f'vm_conf_dir="{work}/vm/"')
(work / 'vzborg').write_text(source)
PY

cat >"$work/bin/mock" <<'MOCK'
#!/usr/bin/env bash
set -u
name=${0##*/}
printf '%s' "$name" >>"$MOCK_LOG"
printf ' %s' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"
case "$name" in
    mktemp)
        if [[ ${FAIL_SECOND_MKTEMP:-0} == 1 ]]; then
            if [[ -e $MKTEMP_MARKER ]]; then exit 1; fi
            : >"$MKTEMP_MARKER"
        fi
        /usr/bin/mktemp "$@"
        ;;
    sendmail)
        cat >"$MOCK_MAIL"
        exit "${FAIL_MAIL:-0}"
        ;;
    pct|qm)
        [[ ${FAIL_GUEST_LIST:-0} == 0 ]] || exit 1
        printf 'ID NAME\n'
        if [[ ${EMPTY_GUESTS:-0} == 0 ]]; then
            if [[ $name == pct ]]; then printf '102 guest102\n'; else printf '101 guest101\n'; fi
        fi
        ;;
    vzdump)
        [[ " ${FAIL_DUMP_IDS:-} " != *" $1 "* ]] || exit 1
        printf 'dump data\n'
        ;;
    borg)
        command=$1
        shift
        case "$command" in
            info|init) [[ ${FAIL_REPOSITORY:-0} == 0 ]] ;;
            create)
                cat >/dev/null
                args=" $* "
                for id in ${FAIL_CREATE_IDS:-}; do
                    [[ $args != *"::vzborg-${id}-"* ]] || exit 1
                done
                ;;
            prune)
                args=" $* "
                for id in ${FAIL_PRUNE_IDS:-}; do
                    [[ $args != *"--prefix vzborg-${id} "* ]] || exit 1
                done
                ;;
            compact)
                if [[ ${SIGNAL_COMPACT:-0} == 1 ]]; then kill -TERM "$PPID"; fi
                [[ ${FAIL_COMPACT:-0} == 0 ]]
                ;;
            list)
                [[ ${FAIL_LIST:-0} == 0 ]] || exit 1
                prefix=''
                while [[ $# -gt 0 ]]; do
                    if [[ $1 == -P ]]; then prefix=$2; break; fi
                    shift
                done
                if [[ $prefix == vzborg- ]]; then
                    [[ ${EMPTY_ARCHIVES:-0} == 1 ]] || printf 'vzborg-101-date.vma\nvzborg-102-date.tar\n'
                else
                    id=${prefix#vzborg-}
                    if [[ " ${MISSING_ARCHIVE_IDS:-} " != *" $id "* ]]; then
                        printf 'vzborg-%s-date.vma ([vm_type]=VM [vm_hostname]=guest%s)\n' "$id" "$id"
                    fi
                fi
                ;;
        esac
        ;;
esac
MOCK
chmod +x "$work/bin/mock"
for name in borg vzdump pct qm sendmail mktemp; do ln -s mock "$work/bin/$name"; done
export PATH="$work/bin:$PATH" MOCK_LOG="$work/log" MOCK_MAIL="$work/mail" MKTEMP_MARKER="$work/mktemp-marker"

run() {
    local expected=$1
    shift
    : >"$MOCK_LOG"
    rm -f "$MOCK_MAIL"
    local status=0
    bash "$work/vzborg" "$@" >"$work/out" 2>"$work/err" || status=$?
    if [[ $status != "$expected" ]]; then
        printf 'Expected exit %s, got %s: %s\n' "$expected" "$status" "$*" >&2
        cat "$work/out" "$work/err" >&2
        exit 1
    fi
    if find "$work/tmp" -type f | grep -q .; then
        printf 'Temporary files leaked: %s\n' "$*" >&2
        exit 1
    fi
}
check() {
    if ! grep -Eq "$1" "$2"; then
        printf 'Missing pattern %s in %s\n' "$1" "$2" >&2
        cat "$2" >&2
        exit 1
    fi
}

run 0 backup -i '101 102' -p
check 'Overall status: SUCCESS' "$work/out"
check 'Failures: backup=0 purge=0 compact=0' "$work/out"
check '^Subject: .* backup default SUCCESS statistics\.' "$MOCK_MAIL"
check '101.*ok.*done' "$MOCK_MAIL"
check '102.*ok.*done' "$MOCK_MAIL"

export FAIL_DUMP_IDS=101 FAIL_CREATE_IDS=102 FAIL_PRUNE_IDS=103 FAIL_COMPACT=1
run 2 backup -i '101 102 103 999' -p
check 'Failures: backup=3 purge=1 compact=1' "$work/out"
check '^Subject: .* backup default FAILED statistics\.' "$MOCK_MAIL"
check '101.*failed.*no' "$MOCK_MAIL"
check '102.*failed.*no' "$MOCK_MAIL"
check '103.*ok.*failed' "$MOCK_MAIL"
check '999.*failed.*no' "$MOCK_MAIL"
if grep -Eq '^borg prune .*--prefix vzborg-(101|102) ' "$MOCK_LOG"; then
    printf 'Failed backup was purged\n' >&2
    exit 1
fi
unset FAIL_DUMP_IDS FAIL_CREATE_IDS FAIL_PRUNE_IDS FAIL_COMPACT

export FAIL_PRUNE_IDS=102 MISSING_ARCHIVE_IDS=999
run 2 purge -i '101 102 999'
check 'Failures: backup=0 purge=2 compact=0' "$work/out"
check '101.*done' "$MOCK_MAIL"
check '102.*failed' "$MOCK_MAIL"
check '999.*failed' "$MOCK_MAIL"
unset FAIL_PRUNE_IDS MISSING_ARCHIVE_IDS

run 0 purge -i all
check 'Overall status: SUCCESS' "$work/out"
run 0 backup -i all
check 'Overall status: SUCCESS' "$work/out"

export FAIL_REPOSITORY=1
run 1 backup -i 101
check 'Overall status: FAILED' "$MOCK_MAIL"
check 'Failed creating' "$MOCK_MAIL"
unset FAIL_REPOSITORY

export EMPTY_GUESTS=1
run 1 backup -i all
check 'No guests to backup' "$work/err"
check 'Overall status: FAILED' "$MOCK_MAIL"
unset EMPTY_GUESTS

export FAIL_GUEST_LIST=1
run 1 backup -i all
check 'Failed to list containers' "$work/err"
check 'Overall status: FAILED' "$MOCK_MAIL"
unset FAIL_GUEST_LIST

export EMPTY_ARCHIVES=1
run 1 purge -i all
check 'No guest backups to purge' "$work/err"
check 'Overall status: FAILED' "$MOCK_MAIL"
unset EMPTY_ARCHIVES

export FAIL_LIST=1
run 1 purge -i all
check 'Failed to list repository archives' "$work/err"
check 'Overall status: FAILED' "$MOCK_MAIL"
run 2 purge -i 101
check 'Failures: backup=0 purge=1 compact=0' "$work/out"
check 'Backup_list_failed' "$MOCK_MAIL"
unset FAIL_LIST

export FAIL_MAIL=1
run 0 backup -i 101
check 'Failed to send backup statistics mail' "$work/err"
export FAIL_DUMP_IDS=101
run 2 backup -i 101
check 'Failed to send backup statistics mail' "$work/err"
unset FAIL_MAIL FAIL_DUMP_IDS

export FAIL_SECOND_MKTEMP=1
run 1 backup -i 101
if [[ -e $MOCK_MAIL ]]; then
    printf 'Incomplete report unexpectedly sent mail\n' >&2
    exit 1
fi
unset FAIL_SECOND_MKTEMP

export SIGNAL_COMPACT=1
run 143 backup -i 101 -p
check 'Overall status: FAILED' "$MOCK_MAIL"
unset SIGNAL_COMPACT

run 0 backup --help
if [[ -e $MOCK_MAIL ]]; then
    printf 'Help unexpectedly sent mail\n' >&2
    exit 1
fi
printf 'Status tests passed.\n'
