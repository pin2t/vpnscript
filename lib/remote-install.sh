# shellcheck shell=bash
#
# vpnscript -- server side install payload. Runs after remote-common.sh.
#
# Expects from the caller: VS_ENDPOINT, VS_CLIENT_COUNT, VS_CLIENT_PREFIX,
# VS_REALITY_SNI, VS_DOH, VS_FORCE.

SYSTEMD_DIR=/usr/lib/systemd/system
[ -d "$SYSTEMD_DIR" ] || SYSTEMD_DIR=/lib/systemd/system

GO_BIN=
GOARCH=
XRAY_ASSET=
BUILD_DIR=

cleanup() { if [ -n "$BUILD_DIR" ]; then rm -rf "$BUILD_DIR"; fi; }
trap cleanup EXIT

# ------------------------------------------------------------------- preflight

vs_preflight() {
	[ "$(id -u)" = 0 ] || die "the remote account must be root"

	local id_like=unknown ver=0
	if [ -r /etc/os-release ]; then
		# shellcheck disable=SC1091
		. /etc/os-release
		id_like=${ID:-unknown}
		ver=${VERSION_ID:-0}; ver=${ver%%.*}
	fi
	case "$id_like" in
		ubuntu) [ "${ver:-0}" -ge 24 ] || warn "Ubuntu ${VERSION_ID:-?} is older than the supported 24.04" ;;
		debian) [ "${ver:-0}" -ge 13 ] || warn "Debian ${VERSION_ID:-?} is older than the supported 13" ;;
		*) warn "untested distribution '$id_like' -- expecting Ubuntu 24+ or Debian 13" ;;
	esac

	case "$(uname -m)" in
		x86_64|amd64)  GOARCH=amd64;  XRAY_ASSET=Xray-linux-64.zip ;;
		aarch64|arm64) GOARCH=arm64;  XRAY_ASSET=Xray-linux-arm64-v8a.zip ;;
		armv7l|armv7)  GOARCH=armv6l; XRAY_ASSET=Xray-linux-arm32-v7a.zip ;;
		*) die "unsupported architecture $(uname -m)" ;;
	esac

	if [ -e "$VS_STATE" ] && [ "$VS_FORCE" != 1 ]; then
		die "vpnscript is already installed on this host.
   Re-running install.sh regenerates every server key and invalidates all
   existing client configs. Use add.sh to hand out more configs, or pass
   --force to wipe and reinstall."
	fi

	command -v systemctl >/dev/null 2>&1 || die "systemd is required"
}

vs_apt() {
	log "installing build and runtime packages"
	export DEBIAN_FRONTEND=noninteractive
	# Ubuntu's needrestart hook otherwise restarts a dozen services -- sshd
	# among them -- in the middle of the install.
	export NEEDRESTART_SUSPEND=1
	apt-get update -qq
	apt-get install -y -qq --no-install-recommends \
		ca-certificates curl unzip git make gcc libc6-dev jq iproute2 iptables procps >/dev/null
}

# ----------------------------------------------------------------- go toolchain

# amneziawg-go tracks a recent Go; the distro packages lag behind it, so a
# private toolchain is dropped in /usr/local/go when needed.
vs_go_ok() {
	local cand=$1 v major minor
	[ -n "$cand" ] && [ -x "$cand" ] || return 1
	v=$("$cand" version 2>/dev/null | awk '{print $3}' | sed 's/^go//')
	case $v in [0-9]*.[0-9]*) ;; *) return 1 ;; esac
	major=${v%%.*}; v=${v#*.}; minor=${v%%.*}
	[ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 25 ]; }
}

vs_setup_go() {
	local cand
	for cand in /usr/local/go/bin/go "$(command -v go 2>/dev/null || true)"; do
		if vs_go_ok "$cand"; then GO_BIN=$cand; ok "using $($cand version)"; return 0; fi
	done

	log "downloading the Go toolchain (needed to build AmneziaWG)"
	local json file sha url tgz
	json=$(curl -fsSL 'https://go.dev/dl/?mode=json')
	file=$(printf '%s' "$json" | jq -r --arg a "$GOARCH" '
		[.[] | select(.stable)][0].files[]
		| select(.os == "linux" and .arch == $a and .kind == "archive")
		| .filename' | head -1)
	sha=$(printf '%s' "$json" | jq -r --arg a "$GOARCH" '
		[.[] | select(.stable)][0].files[]
		| select(.os == "linux" and .arch == $a and .kind == "archive")
		| .sha256' | head -1)
	[ -n "$file" ] && [ -n "$sha" ] || die "could not determine the current Go release for linux/$GOARCH"

	tgz="$BUILD_DIR/$file"
	url="https://go.dev/dl/$file"
	curl -fsSL -o "$tgz" "$url" || die "failed to download $url"
	printf '%s  %s\n' "$sha" "$tgz" | sha256sum -c --quiet - || die "checksum mismatch on $file"

	rm -rf /usr/local/go
	tar -C /usr/local -xzf "$tgz"
	GO_BIN=/usr/local/go/bin/go
	ok "installed $($GO_BIN version)"
}

# ------------------------------------------------------------------- amneziawg

vs_install_amneziawg() {
	local goref=${VS_AWG_GO_REF:-master} toolsref=${VS_AWG_TOOLS_REF:-master}

	log "building amneziawg-go ($goref)"
	git clone -q --depth 1 --branch "$goref" https://github.com/amnezia-vpn/amneziawg-go "$BUILD_DIR/awg-go" 2>/dev/null \
		|| { rm -rf "$BUILD_DIR/awg-go"; git clone -q --depth 1 https://github.com/amnezia-vpn/amneziawg-go "$BUILD_DIR/awg-go"; }
	(
		cd "$BUILD_DIR/awg-go"
		export PATH="$(dirname "$GO_BIN"):$PATH" GOFLAGS=-buildvcs=false GOCACHE="$BUILD_DIR/gocache"
		make
	) > "$BUILD_DIR/awg-go.log" 2>&1 \
		|| die "amneziawg-go build failed: $(tail -15 "$BUILD_DIR/awg-go.log")"

	local bin
	bin=$(find "$BUILD_DIR/awg-go" -maxdepth 1 -type f \( -name amneziawg-go -o -name awg-go \) | head -1)
	[ -n "$bin" ] || die "amneziawg-go build produced no binary"
	install -m 0755 "$bin" "$AWG_GO_BIN"

	log "building amneziawg-tools ($toolsref)"
	git clone -q --depth 1 --branch "$toolsref" https://github.com/amnezia-vpn/amneziawg-tools "$BUILD_DIR/awg-tools" 2>/dev/null \
		|| { rm -rf "$BUILD_DIR/awg-tools"; git clone -q --depth 1 https://github.com/amnezia-vpn/amneziawg-tools "$BUILD_DIR/awg-tools"; }
	(
		cd "$BUILD_DIR/awg-tools/src"
		make -s -j"$(nproc)"
		make -s install PREFIX=/usr SYSCONFDIR=/etc SYSTEMDUNITDIR="$SYSTEMD_DIR" \
			WITH_WGQUICK=yes WITH_SYSTEMDUNITS=yes WITH_BASHCOMPLETION=yes
	) > "$BUILD_DIR/awg-tools.log" 2>&1 \
		|| die "amneziawg-tools build failed: $(tail -15 "$BUILD_DIR/awg-tools.log")"

	command -v awg >/dev/null || die "awg was not installed"
	command -v awg-quick >/dev/null || die "awg-quick was not installed"
	# No kernel module is used: awg-quick falls back to the userspace
	# implementation whenever /sys/module/amneziawg is absent.
	ok "amneziawg-tools + userspace datapath installed"
}

# ------------------------------------------------------------------------ xray

vs_install_xray() {
	log "installing Xray-core"
	local tag json zip want got
	json=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null || true)
	tag=$(printf '%s' "$json" | jq -r '.tag_name // empty')
	if [ -z "$tag" ]; then
		tag=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases | jq -r '.[0].tag_name')
	fi
	[ -n "$tag" ] || die "could not determine the latest Xray-core release"

	zip="$BUILD_DIR/$XRAY_ASSET"
	curl -fsSL -o "$zip"  "https://github.com/XTLS/Xray-core/releases/download/$tag/$XRAY_ASSET"
	curl -fsSL -o "$zip.dgst" "https://github.com/XTLS/Xray-core/releases/download/$tag/$XRAY_ASSET.dgst"
	want=$(sed -n 's/^SHA2-256=[[:space:]]*//p' "$zip.dgst" | tr -d ' \n')
	got=$(sha256sum "$zip" | awk '{print $1}')
	[ -n "$want" ] || die "no SHA2-256 in $XRAY_ASSET.dgst"
	[ "$want" = "$got" ] || die "checksum mismatch on $XRAY_ASSET"

	unzip -o -q "$zip" -d "$BUILD_DIR/xray"
	install -m 0755 "$BUILD_DIR/xray/xray" "$XRAY_BIN"
	install -d -m 0755 "$XRAY_ASSETS"
	install -m 0644 "$BUILD_DIR/xray/geoip.dat" "$BUILD_DIR/xray/geosite.dat" "$XRAY_ASSETS/"
	install -d -m 0755 "$XRAY_ETC"

	id -u xray >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin xray
	install -d -m 0750 -o xray -g xray /var/log/xray

	ok "Xray $tag installed ($("$XRAY_BIN" version | head -1))"
}

# ------------------------------------------------------------------- parameters

vs_generate_params() {
	VS_VERSION=1
	VS_AWG_IF=awg0
	VS_XRAY_TAG=vless-in
	VS_MTU=1280
	VS_DOH=${VS_DOH:-https://1.1.1.1/dns-query,https://9.9.9.9/dns-query}
	VS_MIN_CLIENT_VER=${VS_MIN_CLIENT_VER:-}

	VS_AWG_PORT=$(pick_port)
	VS_XRAY_PORT=$(pick_port)
	while [ "$VS_XRAY_PORT" = "$VS_AWG_PORT" ]; do VS_XRAY_PORT=$(pick_port); done

	local o2 o3 h6
	o2=$(rnd 20 250); o3=$(rnd 1 250)
	VS_NET4_PREFIX="10.$o2.$o3"
	VS_NET4="$VS_NET4_PREFIX.0/24"
	VS_DNS_IP="$VS_NET4_PREFIX.1"
	VS_DNS_IP6=

	# A tunnel-local IPv6 range is only useful when the server itself has
	# working IPv6 connectivity to masquerade behind.
	if ip -6 route show default 2>/dev/null | grep -q . && \
	   ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
		VS_HAS_V6=1
		h6=$(rand_hex 5)
		VS_NET6_PREFIX="fd${h6:0:2}:${h6:2:4}:${h6:6:4}::"
		VS_NET6="${VS_NET6_PREFIX}/64"
		VS_DNS_IP6="${VS_NET6_PREFIX}1"
	else
		VS_HAS_V6=0
		VS_NET6_PREFIX=
		VS_NET6=
	fi

	# AmneziaWG 2.0 obfuscation. Jc/Jmin/Jmax add junk packets before each
	# handshake, S1-S4 pad the four message types, H1-H4 replace the message
	# type constants that make plain WireGuard trivial to fingerprint, and I1
	# is the 2.0 signature packet sent ahead of the handshake.
	VS_JC=$(rnd 4 8)
	VS_JMIN=$(rnd 40 80)
	VS_JMAX=$(rnd 700 1000)
	VS_S1=$(rnd 15 150)
	VS_S2=$(rnd 15 150)
	# Keep the padded init and response messages different sizes.
	while [ "$VS_S2" -eq $(( VS_S1 + 56 )) ]; do VS_S2=$(rnd 15 150); done
	VS_S3=$(rnd 15 64)
	VS_S4=$(rnd 15 32)
	# Header values must stay clear of the real message types 1-4 and of each other.
	VS_H1=$(rnd 5 2147483647)
	VS_H2=$(rnd 5 2147483647); while [ "$VS_H2" = "$VS_H1" ]; do VS_H2=$(rnd 5 2147483647); done
	VS_H3=$(rnd 5 2147483647); while [ "$VS_H3" = "$VS_H1" ] || [ "$VS_H3" = "$VS_H2" ]; do VS_H3=$(rnd 5 2147483647); done
	VS_H4=$(rnd 5 2147483647); while [ "$VS_H4" = "$VS_H1" ] || [ "$VS_H4" = "$VS_H2" ] || [ "$VS_H4" = "$VS_H3" ]; do VS_H4=$(rnd 5 2147483647); done
	VS_I1="<b 0x$(rand_hex 8)><r $(rnd 32 96)>"

	local kp
	kp=$("$XRAY_BIN" x25519)
	VS_REALITY_PRIV=$(printf '%s\n' "$kp" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -1)
	VS_REALITY_PBK=$(printf '%s\n' "$kp"  | sed -n 's/^Password[^:]*:[[:space:]]*//p' | head -1)
	[ -n "$VS_REALITY_PRIV" ] || VS_REALITY_PRIV=$(printf '%s\n' "$kp" | sed -n 's/^Private key:[[:space:]]*//p' | head -1)
	[ -n "$VS_REALITY_PBK" ]  || VS_REALITY_PBK=$(printf '%s\n' "$kp"  | sed -n 's/^Public key:[[:space:]]*//p' | head -1)
	[ -n "$VS_REALITY_PRIV" ] && [ -n "$VS_REALITY_PBK" ] || die "could not parse 'xray x25519' output"
	VS_REALITY_SID=$(rand_hex 8)
	VS_XHTTP_PATH=$(rand_path)

	log "AmneziaWG on udp/$VS_AWG_PORT, Xray XHTTP+REALITY on tcp/$VS_XRAY_PORT"
	log "tunnel $VS_NET4${VS_NET6:+ + $VS_NET6}, DNS $VS_DNS_IP -> $VS_DOH"
}

# --------------------------------------------------------------- server configs

vs_write_awg_conf() {
	local priv conf addr
	priv=$(awg genkey)
	VS_AWG_PUB=$(printf '%s\n' "$priv" | awg pubkey)
	install -d -m 0700 "$AWG_ETC"
	conf="$AWG_ETC/$VS_AWG_IF.conf"
	addr="$VS_NET4_PREFIX.1/24"
	if [ "$VS_HAS_V6" = 1 ]; then addr="$addr, ${VS_NET6_PREFIX}1/64"; fi

	# Peers are appended as blank-line separated blocks; remove.sh relies on it.
	cat > "$conf" <<EOF
# Managed by vpnscript -- use add.sh / remove.sh rather than editing peers here.
[Interface]
Address = $addr
ListenPort = $VS_AWG_PORT
PrivateKey = $priv
MTU = $VS_MTU
Jc = $VS_JC
Jmin = $VS_JMIN
Jmax = $VS_JMAX
S1 = $VS_S1
S2 = $VS_S2
S3 = $VS_S3
S4 = $VS_S4
H1 = $VS_H1
H2 = $VS_H2
H3 = $VS_H3
H4 = $VS_H4
EOF
	chmod 600 "$conf"
}

vs_write_xray_conf() {
	local qs=UseIPv4 dstrat=UseIPv4 listen=0.0.0.0
	if [ "$VS_HAS_V6" = 1 ]; then qs=UseIP; dstrat=UseIP; listen=:: ; fi

	# The dokodemo-door inbound is the plain-DNS endpoint the AmneziaWG clients
	# point at. The port 53 routing rule catches DNS sent through the VLESS
	# tunnel. Both land on the "dns" outbound, which answers A/AAAA from Xray's
	# built-in resolver -- configured below with a DoH upstream -- and returns
	# an empty answer for anything else, so no cleartext DNS ever leaves the
	# server.
	jq -n \
		--arg doh "$VS_DOH" --arg qs "$qs" --arg dstrat "$dstrat" \
		--arg dnsip "$VS_DNS_IP" --arg dnsip6 "$VS_DNS_IP6" \
		--argjson xport "$VS_XRAY_PORT" --arg listen "$listen" \
		--arg tag "$VS_XRAY_TAG" --arg sni "$VS_REALITY_SNI" \
		--arg priv "$VS_REALITY_PRIV" --arg sid "$VS_REALITY_SID" \
		--arg path "$VS_XHTTP_PATH" --arg mcv "$VS_MIN_CLIENT_VER" '
{
  "log": { "loglevel": "warning" },
  "dns": { "servers": ($doh | split(",") | map(select(length > 0))), "queryStrategy": $qs },
  "inbounds": ([
    { "tag": "dns-in", "listen": $dnsip, "port": 53, "protocol": "dokodemo-door",
      "settings": { "address": "1.1.1.1", "port": 53, "network": "tcp,udp" } }
  ] + (if $dnsip6 == "" then [] else [
    { "tag": "dns-in6", "listen": $dnsip6, "port": 53, "protocol": "dokodemo-door",
      "settings": { "address": "1.1.1.1", "port": 53, "network": "tcp,udp" } }
  ] end) + [
    { "tag": $tag, "listen": $listen, "port": $xport, "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network": "xhttp", "security": "reality",
        "realitySettings": ({
          "show": false, "target": ($sni + ":443"), "xver": 0,
          "serverNames": [ $sni ], "privateKey": $priv, "shortIds": [ $sid ]
        } + (if $mcv == "" then {} else { "minClientVer": $mcv } end)),
        "xhttpSettings": { "path": $path, "mode": "auto" }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] } }
  ]),
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": $dstrat } },
    { "tag": "dns-out", "protocol": "dns" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "inboundTag": [ "dns-in", "dns-in6" ], "outboundTag": "dns-out" },
      { "type": "field", "port": 53, "outboundTag": "dns-out" },
      { "type": "field", "ip": [ "geoip:private" ], "outboundTag": "block" }
    ]
  }
}' > "$XRAY_CONF"
	chmod 640 "$XRAY_CONF"
	chown root:xray "$XRAY_CONF"
	"$XRAY_BIN" run -test -format json -config "$XRAY_CONF" >/dev/null 2>&1 \
		|| die "generated Xray config rejected: $("$XRAY_BIN" run -test -format json -config "$XRAY_CONF" 2>&1 | tail -5)"
}

# ------------------------------------------------------------- system plumbing

vs_write_sysctl() {
	{
		printf 'net.ipv4.ip_forward=1\n'
		# Lets Xray bind the tunnel-side DNS address before awg0 exists.
		printf 'net.ipv4.ip_nonlocal_bind=1\n'
		if [ "$VS_HAS_V6" = 1 ]; then
			printf 'net.ipv6.conf.all.forwarding=1\n'
			printf 'net.ipv6.ip_nonlocal_bind=1\n'
		fi
	} > /etc/sysctl.d/99-vpnscript.conf
	sysctl -q --system >/dev/null 2>&1 || sysctl -q -p /etc/sysctl.d/99-vpnscript.conf >/dev/null 2>&1 || true
}

vs_write_firewall() {
	cat > /usr/local/sbin/vpnscript-firewall <<'EOF'
#!/usr/bin/env bash
# Managed by vpnscript. Idempotent: safe to re-run at any time.
#   vpnscript-firewall          install the rules
#   vpnscript-firewall flush    remove them again
set -eu
. /etc/vpnscript/server.env
MODE=${1:-apply}

ensure() { # ensure <cmd> <table> <chain> <rule...>
	local cmd=$1 table=$2 chain=$3; shift 3
	command -v "$cmd" >/dev/null 2>&1 || return 0
	if [ "$MODE" = flush ]; then
		while "$cmd" -t "$table" -C "$chain" "$@" 2>/dev/null; do
			"$cmd" -t "$table" -D "$chain" "$@" 2>/dev/null || break
		done
		return 0
	fi
	"$cmd" -t "$table" -C "$chain" "$@" 2>/dev/null || "$cmd" -t "$table" -I "$chain" 1 "$@"
}

ensure iptables filter INPUT -p udp --dport "$VS_AWG_PORT" -j ACCEPT
ensure iptables filter INPUT -p tcp --dport "$VS_XRAY_PORT" -j ACCEPT
ensure iptables filter INPUT -i "$VS_AWG_IF" -p udp --dport 53 -j ACCEPT
ensure iptables filter INPUT -i "$VS_AWG_IF" -p tcp --dport 53 -j ACCEPT
ensure iptables filter INPUT -i "$VS_AWG_IF" -p icmp -j ACCEPT
# Redirect every DNS query that enters the tunnel to our own resolver, whatever
# server the client is configured to use. Without this a client that ignores the
# pushed DNS sends cleartext queries straight through -- which both leaks and
# breaks resolution wherever the client's own resolver is blocked.
ensure iptables nat PREROUTING -i "$VS_AWG_IF" -p udp --dport 53 -j DNAT --to-destination "$VS_DNS_IP:53"
ensure iptables nat PREROUTING -i "$VS_AWG_IF" -p tcp --dport 53 -j DNAT --to-destination "$VS_DNS_IP:53"

ensure iptables filter FORWARD -i "$VS_AWG_IF" -j ACCEPT
ensure iptables filter FORWARD -o "$VS_AWG_IF" -j ACCEPT
ensure iptables nat POSTROUTING -s "$VS_NET4" ! -o "$VS_AWG_IF" -j MASQUERADE

if [ "${VS_HAS_V6:-0}" = 1 ]; then
	ensure ip6tables filter INPUT -p tcp --dport "$VS_XRAY_PORT" -j ACCEPT
	ensure ip6tables filter INPUT -i "$VS_AWG_IF" -p udp --dport 53 -j ACCEPT
	ensure ip6tables filter INPUT -i "$VS_AWG_IF" -p tcp --dport 53 -j ACCEPT
	ensure ip6tables filter INPUT -i "$VS_AWG_IF" -p ipv6-icmp -j ACCEPT
	if [ -n "${VS_DNS_IP6:-}" ]; then
		ensure ip6tables nat PREROUTING -i "$VS_AWG_IF" -p udp --dport 53 -j DNAT --to-destination "[$VS_DNS_IP6]:53"
		ensure ip6tables nat PREROUTING -i "$VS_AWG_IF" -p tcp --dport 53 -j DNAT --to-destination "[$VS_DNS_IP6]:53"
	fi
	ensure ip6tables filter FORWARD -i "$VS_AWG_IF" -j ACCEPT
	ensure ip6tables filter FORWARD -o "$VS_AWG_IF" -j ACCEPT
	ensure ip6tables nat POSTROUTING -s "$VS_NET6" ! -o "$VS_AWG_IF" -j MASQUERADE
fi

# ufw keeps its own chains; teach it about the listening ports as well.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -qi active; then
	if [ "$MODE" = flush ]; then
		ufw delete allow "$VS_AWG_PORT"/udp  >/dev/null 2>&1 || true
		ufw delete allow "$VS_XRAY_PORT"/tcp >/dev/null 2>&1 || true
	else
		ufw allow "$VS_AWG_PORT"/udp  >/dev/null 2>&1 || true
		ufw allow "$VS_XRAY_PORT"/tcp >/dev/null 2>&1 || true
	fi
fi
EOF
	chmod 0755 /usr/local/sbin/vpnscript-firewall

	cat > "$SYSTEMD_DIR/vpnscript-firewall.service" <<EOF
[Unit]
Description=vpnscript packet filter and NAT rules
After=network-online.target
Wants=network-online.target
Before=awg-quick@$VS_AWG_IF.service xray.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/vpnscript-firewall

[Install]
WantedBy=multi-user.target
EOF
}

vs_write_xray_unit() {
	cat > "$SYSTEMD_DIR/xray.service" <<EOF
[Unit]
Description=Xray Service (managed by vpnscript)
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target awg-quick@$VS_AWG_IF.service
Wants=network-online.target

[Service]
User=xray
Group=xray
Environment=XRAY_LOCATION_ASSET=$XRAY_ASSETS
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=$XRAY_BIN run -config $XRAY_CONF
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

# ------------------------------------------------------------------ verification

vs_verify() {
	local failed=0
	systemctl is-active --quiet "awg-quick@$VS_AWG_IF" || { warn "awg-quick@$VS_AWG_IF is not running"; failed=1; }
	systemctl is-active --quiet xray || { warn "xray is not running"; failed=1; }
	awg show "$VS_AWG_IF" >/dev/null 2>&1 || { warn "interface $VS_AWG_IF did not come up"; failed=1; }

	if [ "$failed" = 1 ]; then
		warn "$(journalctl -u "awg-quick@$VS_AWG_IF" -u xray -n 25 --no-pager 2>&1 | tail -25)"
		die "installation finished with failing services"
	fi

	if command -v python3 >/dev/null 2>&1; then
		cat > "$BUILD_DIR/dnsprobe.py" <<'DNSPROBE'
import random, socket, struct, sys
qid = random.randint(0, 65535)
qname = b''.join(bytes([len(p)]) + p for p in b'example.com'.split(b'.')) + b'\x00'
pkt = struct.pack('>HHHHHH', qid, 0x0100, 1, 0, 0, 0) + qname + struct.pack('>HH', 1, 1)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(8)
sock.sendto(pkt, (sys.argv[1], 53))
data, _ = sock.recvfrom(2048)
sys.exit(0 if struct.unpack('>H', data[6:8])[0] > 0 else 1)
DNSPROBE
		if python3 "$BUILD_DIR/dnsprobe.py" "$VS_DNS_IP" >/dev/null 2>&1; then
			ok "DNS-over-HTTPS resolver answering on $VS_DNS_IP:53"
		else
			warn "the tunnel DNS resolver on $VS_DNS_IP:53 did not answer a test query"
		fi
	fi

	ok "AmneziaWG udp/$VS_AWG_PORT and Xray tcp/$VS_XRAY_PORT are up"
}

# ------------------------------------------------------------------------- main

vs_install_main() {
	BUILD_DIR=$(mktemp -d)
	vs_preflight
	vs_apt

	if [ "$VS_FORCE" = 1 ] && [ -e "$VS_STATE" ]; then
		log "--force: tearing down the previous installation"
		# shellcheck disable=SC1090
		(
			. "$VS_STATE"
			systemctl disable --now "awg-quick@${VS_AWG_IF:-awg0}" >/dev/null 2>&1 || true
			del() {
				local cmd=$1 table=$2 chain=$3; shift 3
				command -v "$cmd" >/dev/null 2>&1 || return 0
				while "$cmd" -t "$table" -C "$chain" "$@" 2>/dev/null; do
					"$cmd" -t "$table" -D "$chain" "$@" 2>/dev/null || break
				done
				return 0
			}
			del iptables nat PREROUTING -i "${VS_AWG_IF:-awg0}" -p udp --dport 53 -j DNAT --to-destination "${VS_DNS_IP:-0.0.0.0}:53"
			del iptables nat PREROUTING -i "${VS_AWG_IF:-awg0}" -p tcp --dport 53 -j DNAT --to-destination "${VS_DNS_IP:-0.0.0.0}:53"
			del iptables nat POSTROUTING -s "${VS_NET4:-10.0.0.0/8}" ! -o "${VS_AWG_IF:-awg0}" -j MASQUERADE
			del iptables filter INPUT -p udp --dport "${VS_AWG_PORT:-0}" -j ACCEPT
			del iptables filter INPUT -p tcp --dport "${VS_XRAY_PORT:-0}" -j ACCEPT
			if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -qi active; then
				ufw delete allow "${VS_AWG_PORT:-0}"/udp  >/dev/null 2>&1 || true
				ufw delete allow "${VS_XRAY_PORT:-0}"/tcp >/dev/null 2>&1 || true
			fi
		)
		systemctl disable --now xray >/dev/null 2>&1 || true
		rm -f "$AWG_ETC"/*.conf
	fi

	vs_setup_go
	vs_install_amneziawg
	vs_install_xray

	install -d -m 0700 "$VS_DIR"
	vs_generate_params
	vs_write_awg_conf
	vs_write_xray_conf
	vs_save_state
	vs_write_sysctl
	vs_write_firewall
	vs_write_xray_unit

	systemctl daemon-reload
	systemctl enable vpnscript-firewall.service >/dev/null 2>&1
	systemctl restart vpnscript-firewall.service || warn "firewall rules could not be applied"
	systemctl enable "awg-quick@$VS_AWG_IF" >/dev/null 2>&1
	systemctl restart "awg-quick@$VS_AWG_IF" || {
		warn "$(journalctl -u "awg-quick@$VS_AWG_IF" -n 25 --no-pager 2>&1 | tail -25)"
		die "the AmneziaWG interface failed to start"
	}
	systemctl enable xray >/dev/null 2>&1
	systemctl restart xray || {
		warn "$(journalctl -u xray -n 25 --no-pager 2>&1 | tail -25)"
		die "xray failed to start"
	}

	local i name
	log "creating $VS_CLIENT_COUNT client profiles"
	i=1
	while [ "$i" -le "$VS_CLIENT_COUNT" ]; do
		name=$(printf '%s%02d' "$VS_CLIENT_PREFIX" "$i")
		vs_add_client "$name"
		i=$(( i + 1 ))
	done

	vs_apply_awg
	vs_apply_xray
	vs_verify
}

vs_install_main
