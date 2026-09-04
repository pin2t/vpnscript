#!/usr/bin/env bash
#
# install.sh -- set up an AmneziaWG 3.1 + Xray XHTTP/REALITY server on a fresh
# Ubuntu 24+ / Debian 13 host and download the client configs.
#
#   ./install.sh root@203.0.113.10

set -euo pipefail

VS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/common.sh
. "$VS_LIB/common.sh"

usage() {
	cat <<'EOF'
Usage: install.sh [options] [user@]host

Installs two independent VPN entry points on the remote host and downloads the
generated client configs to this machine. Nothing is left behind on the server:
client private keys are generated, handed over and dropped.

  AmneziaWG 3.1   obfuscated WireGuard with header protection, random UDP
                  port in 1200-2000
  Xray            VLESS over XHTTP with REALITY, random TCP port in 1200-2000
  DNS             both tunnels resolve through the server, which forwards
                  upstream over DNS-over-HTTPS

Options:
  -o, --output DIR     where to write client configs (default: ./configs/<host>)
  -n, --clients N      number of client profiles to create (default: 10)
  -e, --endpoint HOST  address clients should connect to (default: the ssh host)
      --prefix NAME    client name prefix (default: client)
      --sni DOMAIN     REALITY camouflage domain (default: www.cloudflare.com)
      --doh URL[,URL]  DoH upstreams (default: Cloudflare then Quad9)
      --min-client-ver V   lowest Xray-core version allowed to connect over
                       REALITY; only set this if your client app bundles a
                       core older than the upstream default of 26.3.27
      --force          wipe an existing vpnscript install and start over
  -h, --help           show this help
EOF
}

count=10
outdir=
endpoint=
prefix=client
sni=www.cloudflare.com
doh=
mcv=
force=0
target=

while [ $# -gt 0 ]; do
	case $1 in
		-o|--output)   [ $# -ge 2 ] || vs_die "$1 needs a value"; outdir=$2; shift 2 ;;
		-n|--clients)  [ $# -ge 2 ] || vs_die "$1 needs a value"; count=$2; shift 2 ;;
		-e|--endpoint) [ $# -ge 2 ] || vs_die "$1 needs a value"; endpoint=$2; shift 2 ;;
		--prefix)      [ $# -ge 2 ] || vs_die "$1 needs a value"; prefix=$2; shift 2 ;;
		--sni)         [ $# -ge 2 ] || vs_die "$1 needs a value"; sni=$2; shift 2 ;;
		--doh)         [ $# -ge 2 ] || vs_die "$1 needs a value"; doh=$2; shift 2 ;;
		--min-client-ver) [ $# -ge 2 ] || vs_die "$1 needs a value"; mcv=$2; shift 2 ;;
		--force)       force=1; shift ;;
		-h|--help)     usage; exit 0 ;;
		--)            shift; break ;;
		-*)            vs_die "unknown option '$1' (try --help)" ;;
		*)             if [ -n "$target" ]; then vs_die "unexpected argument '$1'"; fi; target=$1; shift ;;
	esac
done
if [ -z "$target" ] && [ $# -gt 0 ]; then target=$1; fi

vs_need ssh
vs_need awk
vs_check_target "${target:-}"

case $count in
	''|*[!0-9]*) vs_die "--clients takes a number" ;;
esac
[ "$count" -ge 1 ] && [ "$count" -le 250 ] || vs_die "--clients must be between 1 and 250"

host=$(vs_target_host "$target")
: "${endpoint:=$host}"
: "${outdir:=configs/$host}"

case $endpoint in
	10.*|127.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|localhost)
		vs_warn "'$endpoint' is not a public address -- clients will not reach it from outside."
		vs_warn "Pass --endpoint with the server's public address if this is wrong." ;;
esac

mkdir -p "$outdir"
payload=$(mktemp "${TMPDIR:-/tmp}/vpnscript.XXXXXX")
trap 'rm -f "$payload"' EXIT

vs_log "installing on $target (endpoint $endpoint, $count clients)"
vs_log "this takes a few minutes: a Go toolchain is fetched to build AmneziaWG"

vs_run_remote "$target" remote-install.sh \
	VS_COLOR="$VS_COLOR" \
	VS_ENDPOINT="$endpoint" \
	VS_CLIENT_COUNT="$count" \
	VS_CLIENT_PREFIX="$prefix" \
	VS_REALITY_SNI="$sni" \
	VS_DOH="$doh" \
	VS_MIN_CLIENT_VER="$mcv" \
	VS_FORCE="$force" > "$payload"

written=$(vs_split_payload "$payload" "$outdir")
[ -n "$written" ] || vs_die "the server produced no client configs"
printf '%s\n' "$written" | while IFS= read -r f; do chmod 600 "$f"; done

n=$(printf '%s\n' "$written" | grep -c '\.conf$' || true)
vs_ok "$(printf '%s\n' "$written" | wc -l | tr -d ' ') files for $n clients in $outdir/"
cat >&2 <<EOF

  ${L_B}AmneziaWG${L_0}  <name>.conf        import into the AmneziaVPN app, or
                                     awg-quick up <name> on Linux
  ${L_B}Xray${L_0}       <name>.vless.url   paste into v2rayN / NekoBox / Hiddify
             <name>.xray.json   or run: xray run -c <name>.xray.json

  ${L_D}Add another client:  ./add.sh $target${L_0}
  ${L_D}Revoke one:          ./remove.sh $target $outdir/${prefix}01.conf${L_0}
  ${L_D}See who is using it: ./stat.sh $target${L_0}
EOF
