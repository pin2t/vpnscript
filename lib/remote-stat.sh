# shellcheck shell=bash
#
# vpnscript -- server side "show client statistics" payload. Read only: nothing
# on the server is touched. VS_ONLY is awg, xray or both.
#
# AmneziaWG keeps per-peer counters in the tunnel itself. Xray keeps them only
# when its stats API is turned on: installs from this repo do turn it on, older
# ones are upgraded with VS_ENABLE=1 (stat.sh --enable-stats), and where it is
# missing the traffic columns are simply left out. When a client was last seen,
# and from where, is read out of the access log xray writes to the journal.

VS_ACTIVE=180      # a WireGuard peer rehandshakes every ~2 min while in use
VS_RECENT=86400
VS_LOG_LINES=200000

: "${VS_TCOLOR:=0}"
if [ "$VS_TCOLOR" = 1 ]; then
	T_B=$'\033[1;34m'; T_G=$'\033[1;32m'; T_Y=$'\033[1;33m'; T_D=$'\033[2m'; T_0=$'\033[0m'
else
	T_B=; T_G=; T_Y=; T_D=; T_0=
fi

# ------------------------------------------------------------ shared awk parts
#
# Prepended to the row builders below. `now`, `active` and `recent` come in as
# -v assignments; mawk has no systime()/mktime(), so every timestamp is turned
# into an epoch by the shell before it reaches awk.
VS_AWK_FMT='
function bytes(b,   i, u) {
	split("B KiB MiB GiB TiB PiB", u, " ")
	i = 1
	while (b >= 1024 && i < 6) { b /= 1024; i++ }
	return (i == 1) ? sprintf("%d B", b) : sprintf("%.2f %s", b, u[i])
}
function ago(n, w) { return n " " w (n == 1 ? "" : "s") " ago" }
function rel(t,   d) {
	if (t <= 0) return "never"
	d = now - t
	if (d < 0) d = 0
	if (d < 60)       return "just now"
	if (d < 3600)     return int(d / 60) " min ago"
	if (d < 86400)    return ago(int(d / 3600), "hour")
	if (d < 604800)   return ago(int(d / 86400), "day")
	if (d < 2629800)  return ago(int(d / 604800), "week")
	if (d < 31557600) return ago(int(d / 2629800), "month")
	return ago(int(d / 31557600), "year")
}
function state(t,   d) {
	if (t <= 0) return "Inactive"
	d = now - t
	if (d <= active) return "Active"
	if (d <= recent) return "Recent"
	return "Inactive"
}
'

# ---------------------------------------------------------------------- table
#
# Reads tab separated rows, first one being the header, and prints them padded
# to a common width. Only the last column is left unpadded, which is what lets
# the status be colourised without the escapes throwing the alignment off.
vs_table() {
	awk -F'\t' -v g="$T_G" -v y="$T_Y" -v d="$T_D" -v z="$T_0" '
	function paint(v) {
		if (v == "Active")   return g v z
		if (v == "Recent")   return y v z
		if (v == "Inactive") return d v z
		return v
	}
	{
		for (i = 1; i <= NF; i++) {
			cell[NR, i] = $i
			if (length($i) > w[i]) w[i] = length($i)
		}
		if (NF > cols) cols = NF
		rows = NR
	}
	END {
		if (rows == 0) exit
		for (i = 1; i <= cols; i++) {
			n = w[i] + (i < cols ? 3 : 0)
			while (n-- > 0) rule = rule "-"
		}
		for (r = 1; r <= rows; r++) {
			line = ""
			for (i = 1; i < cols; i++) line = line sprintf("%-" w[i] "s | ", cell[r, i])
			line = line (r == 1 ? cell[r, cols] : paint(cell[r, cols]))
			print line
			if (r == 1) print rule
		}
	}'
}

# ------------------------------------------------------------------ amneziawg

# One row per peer: idx (for sorting only) name ip received sent seen status.
# The peer names live in awg0.conf as the comment above each [Peer] block, the
# counters come from `awg show <if> dump`, which is read on stdin.
vs_awg_rows() {
	awk -v now="$(date +%s)" -v active="$VS_ACTIVE" -v recent="$VS_RECENT" \
		"$VS_AWK_FMT"'
	FNR == NR {
		if ($1 == "#" && $2 == "vpnscript-peer") { nm = substr($3, 6); ix = substr($4, 5) + 0; next }
		if ($1 == "PublicKey" && nm != "") { name[$3] = nm; ixof[$3] = ix; nm = "" }
		next
	}
	# The first dump line describes the interface itself. AmneziaWG pads it out
	# with its obfuscation values, so it is far wider than a peer line and has
	# to be skipped by position rather than by field count.
	++line == 1 { next }
	NF >= 8 {
		ip = $4
		sub(/,.*/, "", ip)
		sub(/\/.*/, "", ip)
		printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\n", \
			($1 in ixof) ? ixof[$1] : 999, \
			($1 in name) ? name[$1] : substr($1, 1, 8) "...", \
			ip, bytes($6), bytes($7), rel($5), state($5)
	}' "$1" -
}

# Fallback for a downed interface: names and addresses straight from the conf.
vs_awg_conf_rows() {
	awk '
	$1 == "#" && $2 == "vpnscript-peer" { nm = substr($3, 6); ix = substr($4, 5) + 0; next }
	$1 == "AllowedIPs" && nm != "" {
		ip = $3
		sub(/,.*/, "", ip)
		sub(/\/.*/, "", ip)
		printf "%d\t%s\t%s\n", ix, nm, ip
		nm = ""
	}' "$1"
}

vs_awg_report() {
	local conf dump
	conf=$(vs_awg_conf)
	printf '%sAmneziaWG%s  %s  udp/%s\n' "$T_B" "$T_0" "$VS_AWG_IF" "$VS_AWG_PORT"
	if [ ! -s "$conf" ]; then
		warn "$conf is missing -- nothing to report"
		return
	fi

	dump=$(awg show "$VS_AWG_IF" dump 2>/dev/null || true)
	if [ -z "$dump" ]; then
		warn "$VS_AWG_IF is down -- traffic and handshake columns omitted"
		{ printf 'Name\tIP\n'; vs_awg_conf_rows "$conf" | sort -n | cut -f2-; } | vs_table
		return
	fi

	{
		printf 'Name\tIP\tReceived\tSent\tSeen\tStatus\n'
		printf '%s\n' "$dump" | vs_awg_rows "$conf" | sort -n | cut -f2-
	} | vs_table
}

# ----------------------------------------------------------------------- xray

vs_xray_clients() {
	jq -r --arg t "$VS_XRAY_TAG" \
		'.inbounds[]? | select(.tag == $t) | .settings.clients[]?.email // empty' \
		"$XRAY_CONF" 2>/dev/null || true
}

# The loopback port xray's gRPC API listens on, empty when it is not enabled.
vs_xray_api_port() {
	jq -r 'if (.stats | type) == "object"
	       then ((.api.tag // "api") as $t | .inbounds[]? | select(.tag == $t) | .port)
	       else empty end' "$XRAY_CONF" 2>/dev/null | head -1
}

# name<TAB>received<TAB>sent for every client the API has counters for. Xray
# creates a counter the first time a client sends anything, so a client that has
# never connected is simply absent -- the caller reads that as zero.
#
# The counters live in memory: they start again from zero whenever xray is
# restarted, which add.sh and remove.sh both do.
vs_xray_traffic() {
	local out
	# A failed query means no usable API, which is not the same as an API that
	# answers with nothing, so the exit status has to survive the pipeline.
	out=$("$XRAY_BIN" api statsquery --server="127.0.0.1:$1" -pattern "user>>>" 2>/dev/null) || return 1
	printf '%s' "$out" | jq -r '
		[ .stat[]? | (.name | split(">>>")) as $p
		  | select(($p | length) == 4 and $p[0] == "user" and $p[2] == "traffic")
		  | { name: $p[1], dir: $p[3], v: ((.value // "0") | tonumber) } ]
		| group_by(.name)[]
		| [ .[0].name,
		    ((map(select(.dir == "uplink")   | .v) | add) // 0),
		    ((map(select(.dir == "downlink") | .v) | add) // 0) ]
		| @tsv' 2>/dev/null || true
}

# Last access log line per client, as "name<TAB>epoch<TAB>source-ip".
#
# xray logs every accepted connection to stdout, which systemd files under the
# xray unit. The journal is read newest first so the scan can stop as soon as
# every client has been seen; only the most recent VS_LOG_LINES entries, and
# only ones from this installation, are looked at -- which also keeps a busy
# server from being trawled end to end.
vs_xray_seen() {
	local want=$1 scan name ts src epoch since=()
	# --force reinstalls hand the same names to brand new clients, so anything
	# logged before this installation says nothing about the clients it has.
	[ -n "${VS_INSTALLED_AT:-}" ] && since=(--since "@$VS_INSTALLED_AT")
	scan=$(journalctl -u xray -o cat -r -n "$VS_LOG_LINES" "${since[@]}" --no-pager 2>/dev/null | awk -v want="$want" '
		{
			e = ""
			for (i = NF; i > 1; i--) if ($(i - 1) == "email:") { e = $i; break }
			if (e == "" || (e in seen)) next
			src = ""
			for (i = 1; i < NF; i++) if ($i == "from") { src = $(i + 1); break }
			if (src == "") src = $3
			if (src ~ /^\[/) { sub(/^\[/, "", src); sub(/\].*/, "", src) }
			else sub(/:[0-9]+$/, "", src)
			ts = $1 " " $2
			sub(/\.[0-9]+$/, "", ts)   # xray logs microseconds; date does not want them
			seen[e] = 1
			print e "\t" ts "\t" src
			if (++found >= want) exit
		}' || true)
	[ -n "$scan" ] || return 0

	# xray stamps its own local "YYYY/MM/DD hh:mm:ss"; date only takes dashes.
	while IFS=$'\t' read -r name ts src; do
		[ -n "$name" ] || continue
		epoch=$(date -d "${ts//\//-}" +%s 2>/dev/null || echo 0)
		printf '%s\t%s\t%s\n' "$name" "$epoch" "$src"
	done <<< "$scan"
}

vs_xray_report() {
	local clients n seen traffic='' port header wseen=0 wtraf=0
	printf '%sXray%s  vless/reality  tcp/%s\n' "$T_B" "$T_0" "$VS_XRAY_PORT"
	clients=$(vs_xray_clients)
	if [ -z "$clients" ]; then
		warn "no Xray clients configured"
		return
	fi
	n=$(printf '%s\n' "$clients" | wc -l | tr -d ' ')

	seen=$(vs_xray_seen "$n")
	[ -n "$seen" ] && wseen=1

	# An API that answers means the counters are real, even when it hands back
	# nothing at all -- that is a server nobody has connected to yet.
	port=$(vs_xray_api_port)
	if [ -n "$port" ] && traffic=$(vs_xray_traffic "$port"); then
		wtraf=1
	fi

	header=Name
	[ "$wseen" = 1 ] && header="$header	Source"
	[ "$wtraf" = 1 ] && header="$header	Received	Sent"
	[ "$wseen" = 1 ] && header="$header	Seen	Status"

	if [ "$wtraf" = 0 ]; then
		warn "xray stats API is off -- traffic columns omitted (turn it on: stat.sh --enable-stats)"
	fi
	if [ "$wseen" = 0 ]; then
		warn "no Xray connections in the journal -- source, seen and status columns omitted"
	fi

	{
		printf '%s\n' "$header"
		# One stream, three kinds of line: S)een, T)raffic, then the C)lients
		# in config order, which is what actually gets printed.
		{
			printf '%s\n' "$seen"    | sed 's/^/S	/'
			printf '%s\n' "$traffic" | sed 's/^/T	/'
			printf '%s\n' "$clients" | sed 's/^/C	/'
		} | awk -F'\t' -v now="$(date +%s)" -v active="$VS_ACTIVE" -v recent="$VS_RECENT" \
			-v wseen="$wseen" -v wtraf="$wtraf" "$VS_AWK_FMT"'
		$2 == "" { next }
		$1 == "S" { at[$2] = $3; ip[$2] = $4; next }
		$1 == "T" { up[$2] = $3; dn[$2] = $4; next }
		$1 == "C" {
			n = $2
			row = n
			if (wseen) row = row "\t" (((n in ip) && ip[n] != "") ? ip[n] : "-")
			if (wtraf) row = row "\t" bytes(up[n] + 0) "\t" bytes(dn[n] + 0)
			if (wseen) { t = (n in at) ? at[n] : 0; row = row "\t" rel(t) "\t" state(t) }
			print row
		}'
	} | vs_table
}

# --------------------------------------------------------------- enabling stats
#
# Older servers were installed before the stats API existed. Adding it is a
# config edit and an xray restart, so it stays behind an explicit flag rather
# than happening the first time someone asks for a report.
vs_xray_enable_stats() {
	local port
	port=$(vs_xray_api_port)
	if [ -n "$port" ]; then
		ok "xray stats API is already on (127.0.0.1:$port)"
		return
	fi
	port=$(pick_port)
	log "enabling the xray stats API on 127.0.0.1:$port"
	vs_xray_edit --argjson p "$port" '
		.stats = (.stats // {})
		| .api = { "tag": "api", "services": [ "StatsService" ] }
		| .policy = ((.policy // {}) * { "levels": { "0": {
			"statsUserUplink": true, "statsUserDownlink": true } } })
		| .inbounds = ([ { "tag": "api", "listen": "127.0.0.1", "port": $p,
			"protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" } } ]
			+ (.inbounds | map(select(.tag != "api"))))
		| .routing.rules = ([ { "type": "field", "inboundTag": [ "api" ], "outboundTag": "api" } ]
			+ ((.routing.rules // []) | map(select((.outboundTag // "") != "api"))))'
	VS_XRAY_API_PORT=$port
	vs_save_state
	vs_apply_xray
	ok "xray restarted -- counters start from zero and run until the next restart"
}

# ------------------------------------------------------------------------ main

vs_stat_main() {
	[ "$(id -u)" = 0 ] || die "the remote account must be root"
	vs_load_state
	command -v jq >/dev/null 2>&1 || die "jq is missing -- is this host really a vpnscript server?"

	if [ "${VS_ENABLE:-0}" = 1 ]; then
		vs_xray_enable_stats
	fi

	if [ "$VS_ONLY" != xray ]; then
		vs_awg_report
	fi
	if [ "$VS_ONLY" != awg ]; then
		[ "$VS_ONLY" = xray ] || printf '\n'
		vs_xray_report
	fi
}

vs_stat_main
