#!/usr/bin/env bash
#
# add.sh -- issue one more client profile on a host set up by install.sh and
# download it. The configs are never stored on the server.
#
#   ./add.sh root@203.0.113.10
#   ./add.sh root@203.0.113.10 laptop

set -euo pipefail

VS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/common.sh
. "$VS_LIB/common.sh"

usage() {
	cat <<'EOF'
Usage: add.sh [options] [user@]host [client-name]

Creates one new client on an already installed server -- an AmneziaWG peer and
an Xray VLESS user under the same name -- and downloads its three config files.
Without a name the next free client<NN> is used.

Options:
  -o, --output DIR   where to write the configs (default: ./configs/<host>)
      --prefix NAME  prefix used when auto-naming (default: client)
  -h, --help         show this help
EOF
}

outdir=
prefix=client
target=
name=

while [ $# -gt 0 ]; do
	case $1 in
		-o|--output) [ $# -ge 2 ] || vs_die "$1 needs a value"; outdir=$2; shift 2 ;;
		--prefix)    [ $# -ge 2 ] || vs_die "$1 needs a value"; prefix=$2; shift 2 ;;
		-h|--help)   usage; exit 0 ;;
		--)          shift; break ;;
		-*)          vs_die "unknown option '$1' (try --help)" ;;
		*)
			if   [ -z "$target" ]; then target=$1
			elif [ -z "$name" ];   then name=$1
			else vs_die "unexpected argument '$1'"
			fi
			shift ;;
	esac
done

vs_need ssh
vs_need awk
vs_check_target "${target:-}"

case ${name:-x} in
	*[!A-Za-z0-9._-]*) vs_die "client name may only contain letters, digits, dot, underscore and dash" ;;
esac

host=$(vs_target_host "$target")
: "${outdir:=configs/$host}"

mkdir -p "$outdir"
payload=$(mktemp "${TMPDIR:-/tmp}/vpnscript.XXXXXX")
trap 'rm -f "$payload"' EXIT

vs_run_remote "$target" remote-add.sh \
	VS_COLOR="$VS_COLOR" \
	VS_NAME="$name" \
	VS_CLIENT_PREFIX="$prefix" > "$payload"

written=$(vs_split_payload "$payload" "$outdir")
[ -n "$written" ] || vs_die "the server produced no client config"
printf '%s\n' "$written" | while IFS= read -r f; do chmod 600 "$f"; done

vs_ok "downloaded to $outdir/"
printf '%s\n' "$written" | sed 's/^/     /' >&2
