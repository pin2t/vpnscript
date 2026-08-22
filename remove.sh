#!/usr/bin/env bash
#
# remove.sh -- revoke a client using the config file that was handed to it.
#
#   ./remove.sh root@203.0.113.10 configs/203.0.113.10/client01.conf

set -euo pipefail

VS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/common.sh
. "$VS_LIB/common.sh"

usage() {
	cat <<'EOF'
Usage: remove.sh [options] [user@]host CONFIG [CONFIG ...]
       remove.sh [options] [user@]host --name CLIENT

Revokes the client that a config file belongs to. An AmneziaWG .conf is matched
by its key, an Xray .xray.json / .vless.url by its uuid. Configs written by
install.sh and add.sh also carry the client name, in which case the client's
entry in the other protocol is revoked as well, so one file is enough.

Options:
      --name CLIENT   revoke by client name instead of by config file
      --only WHICH    limit removal to "awg" or "xray" (default: both)
  -h, --help          show this help

The local config files are left alone; delete them yourself once you are done.
EOF
}

only=both
target=
names=
files=

while [ $# -gt 0 ]; do
	case $1 in
		--name) [ $# -ge 2 ] || vs_die "--name needs a value"; names="$names$2"$'\n'; shift 2 ;;
		--only)
			[ $# -ge 2 ] || vs_die "--only needs a value"
			case $2 in awg|xray|both) only=$2 ;; *) vs_die "--only takes awg, xray or both" ;; esac
			shift 2 ;;
		-h|--help) usage; exit 0 ;;
		--)        shift; break ;;
		-*)        vs_die "unknown option '$1' (try --help)" ;;
		*)
			if [ -z "$target" ]; then target=$1; else files="$files$1"$'\n'; fi
			shift ;;
	esac
done
while [ $# -gt 0 ]; do files="$files$1"$'\n'; shift; done

vs_need ssh
vs_check_target "${target:-}"
[ -n "$files$names" ] || { usage >&2; vs_die "give at least one config file or --name"; }

# Build one record per client: name, AmneziaWG private key, uuid, joined with
# ASCII unit separators so that empty fields survive the remote-side read.
# Records are deduplicated by name so passing all three files of one client does
# not try to revoke it three times.
specs=
seen=
add_spec() { specs="$specs$1"$'\037'"$2"$'\037'"$3"$'\n'; }

if [ -n "$names" ]; then
	while IFS= read -r n; do
		[ -n "$n" ] || continue
		add_spec "$n" "" ""
		seen="$seen$n"$'\n'
	done <<< "$names"
fi

if [ -n "$files" ]; then
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		[ -r "$f" ] || vs_die "cannot read '$f'"
		n=$(vs_extract_name "$f")
		priv=$(vs_extract_awg_priv "$f")
		uuid=$(vs_extract_uuid "$f")
		if [ -z "$n$priv$uuid" ]; then
			vs_die "'$f' does not look like a vpnscript client config"
		fi
		if [ -n "$n" ] && printf '%s' "$seen" | grep -qx "$n"; then
			continue
		fi
		add_spec "$n" "$priv" "$uuid"
		if [ -n "$n" ]; then seen="$seen$n"$'\n'; fi
	done <<< "$files"
fi

[ -n "$specs" ] || vs_die "nothing to remove"

vs_run_remote "$target" remote-remove.sh \
	VS_COLOR="$VS_COLOR" \
	VS_ONLY="$only" \
	VS_SPECS="${specs%$'\n'}"
