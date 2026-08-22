# shellcheck shell=bash
#
# vpnscript -- server side "add one client" payload. Expects VS_NAME (may be
# empty, in which case the next free <prefix>NN is used) and VS_CLIENT_PREFIX.

vs_add_main() {
	vs_load_state

	local name=$VS_NAME i cand
	if [ -z "$name" ]; then
		i=1
		while [ "$i" -le 254 ]; do
			cand=$(printf '%s%02d' "$VS_CLIENT_PREFIX" "$i")
			if ! vs_client_exists "$cand"; then name=$cand; break; fi
			i=$(( i + 1 ))
		done
		[ -n "$name" ] || die "no free client name left"
	fi

	vs_add_client "$name"
	vs_apply_awg
	vs_apply_xray
	ok "client '$name' is live on $VS_ENDPOINT"
}

vs_add_main
