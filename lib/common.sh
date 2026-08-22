# shellcheck shell=bash
#
# vpnscript -- helpers for the machine you run the scripts from.

if [ -t 2 ]; then
	L_B=$'\033[1;34m'; L_G=$'\033[1;32m'; L_Y=$'\033[1;33m'; L_R=$'\033[1;31m'; L_D=$'\033[2m'; L_0=$'\033[0m'
	VS_COLOR=1
else
	L_B=; L_G=; L_Y=; L_R=; L_D=; L_0=; VS_COLOR=0
fi

vs_log()  { printf '%s::%s %s\n'  "$L_B" "$L_0" "$*" >&2; }
vs_ok()   { printf '%s ok%s %s\n' "$L_G" "$L_0" "$*" >&2; }
vs_warn() { printf '%s !!%s %s\n' "$L_Y" "$L_0" "$*" >&2; }
vs_die()  { printf '%s xx%s %s\n' "$L_R" "$L_0" "$*" >&2; exit 1; }

vs_need() { command -v "$1" >/dev/null 2>&1 || vs_die "'$1' is required on this machine but was not found"; }

# ------------------------------------------------------------------ ssh target

# vs_target_host user@host -> host  (also copes with host:port and [v6]:port)
vs_target_host() {
	local t=${1#*@}
	case $t in
		\[*\]*) t=${t%%]*}; t=${t#[} ;;
		*:*)    t=${t%%:*} ;;
	esac
	printf '%s\n' "$t"
}

vs_check_target() {
	case $1 in
		''|-*) vs_die "expected an ssh target such as root@203.0.113.10" ;;
	esac
	[ -n "$(vs_target_host "$1")" ] || vs_die "could not parse a hostname out of '$1'"
}

# ------------------------------------------------------------- remote payloads

# vs_run_remote TARGET PAYLOAD [VAR=VALUE ...]
#
# Ships lib/remote-common.sh plus the payload to the server over ssh. Variables
# are shell-quoted into a prelude so no argument quoting has to survive the ssh
# command line. Remote progress goes to stderr; stdout carries client files.
vs_run_remote() {
	local target=$1 payload=$2
	shift 2
	local prelude='' kv k v
	for kv in "$@"; do
		k=${kv%%=*}
		v=${kv#*=}
		prelude="$prelude$k=$(printf '%q' "$v")"$'\n'
	done
	{
		printf '%s' "$prelude"
		cat "$VS_LIB/remote-common.sh" "$VS_LIB/$payload"
	} | ssh -o ConnectTimeout=15 "$target" bash -s
}

# --------------------------------------------------------------- file payloads

# vs_split_payload PAYLOAD_FILE OUTDIR -- writes each embedded file, prints paths
vs_split_payload() {
	awk -v dir="$2" '
		/^__VPNSCRIPT_FILE__ / {
			name = $2
			gsub(/[^A-Za-z0-9._-]/, "_", name)
			path = dir "/" name
			printf "" > path
			print path
			next
		}
		/^__VPNSCRIPT_EOF__$/ { if (path != "") { close(path); path = "" } next }
		path != "" { print > path }
	' "$1"
}

# ------------------------------------------------- reading back a client config

# The three files handed out per client all carry the client name, so a config
# can be traced back to the server-side entries that need deleting.
vs_extract_name() {
	{
		sed -n 's/^#[[:space:]]*vpnscript-client[[:space:]]*=[[:space:]]*//p' "$1"
		sed -n 's/.*"_vpnscript_client"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1"
		sed -n 's|^vless://.*#||p' "$1"
	} 2>/dev/null | tr -d ' \r' | grep -E '^[A-Za-z0-9._-]+$' | head -1 || true
}

vs_extract_awg_priv() {
	sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*\([A-Za-z0-9+/]\{42,43\}=\).*/\1/p' "$1" 2>/dev/null | head -1 || true
}

vs_extract_uuid() {
	grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "$1" 2>/dev/null | head -1 || true
}
