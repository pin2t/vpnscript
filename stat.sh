#!/usr/bin/env bash
#
# stat.sh -- show what every client on a vpnscript server is up to.
#
#   ./stat.sh root@203.0.113.10

set -euo pipefail

VS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/common.sh
. "$VS_LIB/common.sh"

usage() {
	cat <<'USAGE'
Usage: stat.sh [options] [user@]host

Prints one table per protocol: the AmneziaWG peers and the Xray clients, each
with the bytes they moved, when they were last seen and from where. Reporting
changes nothing on the server.

Seen is relative ("3 min ago", "2 weeks ago") and Status follows from it:
Active within 3 minutes, Recent within a day, Inactive after that.

Xray only counts bytes per client when its stats API is on. Servers installed
by this version have it; on an older one --enable-stats turns it on -- that
edits the Xray config and restarts the daemon, the one thing stat.sh can
change on a server.

Options:
      --only WHICH    limit the report to "awg" or "xray" (default: both)
      --enable-stats  switch the Xray stats API on first, then report
  -h, --help          show this help
USAGE
}

only=both
enable=0
target=

while [ $# -gt 0 ]; do
	case $1 in
		--only)
			[ $# -ge 2 ] || vs_die "--only needs a value"
			case $2 in awg|xray|both) only=$2 ;; *) vs_die "--only takes awg, xray or both" ;; esac
			shift 2 ;;
		--enable-stats) enable=1; shift ;;
		-h|--help) usage; exit 0 ;;
		--)        shift; break ;;
		-*)        vs_die "unknown option '$1' (try --help)" ;;
		*)         if [ -n "$target" ]; then vs_die "unexpected argument '$1'"; fi; target=$1; shift ;;
	esac
done
if [ -z "$target" ] && [ $# -gt 0 ]; then target=$1; fi

vs_need ssh
vs_check_target "${target:-}"

# The tables go to stdout, the log lines to stderr, so the two get their colours
# from whichever of the two is a terminal.
tcolor=0
if [ -t 1 ]; then tcolor=1; fi

vs_run_remote "$target" remote-stat.sh \
	VS_COLOR="$VS_COLOR" \
	VS_TCOLOR="$tcolor" \
	VS_ONLY="$only" \
	VS_ENABLE="$enable"
