# shellcheck shell=bash
#
# vpnscript -- server side "remove clients" payload.
#
# VS_SPECS holds one "name<US>privkey<US>uuid" record per line, separated by
# ASCII unit separators -- not tabs, because IFS whitespace would collapse the
# empty fields. Any field may be empty. VS_ONLY is awg, xray or both.

vs_peer_name_by_pubkey() {
	awk -v k="$1" '
		BEGIN { RS = "" }
		index($0, k) && match($0, /name=[A-Za-z0-9._-]+/) {
			print substr($0, RSTART + 5, RLENGTH - 5)
		}' "$(vs_awg_conf)" 2>/dev/null | head -1
}

vs_client_name_by_uuid() {
	jq -r --arg id "$1" --arg t "$VS_XRAY_TAG" '
		.inbounds[]? | select(.tag == $t) | .settings.clients[]?
		| select(.id == $id) | .email // empty' "$XRAY_CONF" 2>/dev/null | head -1
}

vs_remove_main() {
	vs_load_state

	local touched_awg=0 touched_xray=0 any=0
	local name priv uuid pub gone_awg gone_xray

	while IFS=$'\037' read -r name priv uuid; do
		[ -n "$name$priv$uuid" ] || continue

		pub=
		if [ -n "$priv" ]; then
			pub=$(printf '%s\n' "$priv" | awg pubkey 2>/dev/null || true)
			[ -n "$pub" ] || warn "could not derive a public key from the supplied private key"
		fi

		# A config identifies one client; resolve its name so the matching
		# entry in the other protocol is cleaned up too.
		if [ -z "$name" ] && [ -n "$pub" ]; then name=$(vs_peer_name_by_pubkey "$pub"); fi
		if [ -z "$name" ] && [ -n "$uuid" ]; then name=$(vs_client_name_by_uuid "$uuid"); fi

		gone_awg=0
		gone_xray=0

		if [ "$VS_ONLY" != xray ]; then
			if [ -n "$pub" ] && vs_remove_awg_peer "$pub"; then
				gone_awg=1
			elif [ -n "$name" ] && vs_remove_awg_peer "# vpnscript-peer name=$name "; then
				gone_awg=1
			fi
		fi

		if [ "$VS_ONLY" != awg ]; then
			if [ -n "$uuid" ] && vs_remove_xray_client uuid "$uuid"; then
				gone_xray=1
			elif [ -n "$name" ] && vs_remove_xray_client email "$name"; then
				gone_xray=1
			fi
		fi

		if [ "$gone_awg" = 1 ] || [ "$gone_xray" = 1 ]; then
			any=1
			local what=
			if [ "$gone_awg" = 1 ]; then touched_awg=1; what="AmneziaWG peer"; fi
			if [ "$gone_xray" = 1 ]; then touched_xray=1; what="${what:+$what and }Xray user"; fi
			ok "removed ${name:-client}: $what"
		else
			warn "no server-side entry matched ${name:-the supplied config} -- already removed?"
		fi
	done <<< "$VS_SPECS"

	if [ "$touched_awg" = 1 ]; then vs_apply_awg; fi
	if [ "$touched_xray" = 1 ]; then vs_apply_xray; fi

	if [ "$any" = 0 ]; then
		die "nothing was removed"
	fi
	log "$(vs_list_clients | wc -l | tr -d ' ') client(s) remain on $VS_ENDPOINT"
}

vs_remove_main
