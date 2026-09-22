#!/bin/ash
set -e
APP="podkop-sub-sync"
BACKUP_DIR="/root/${APP}-backup-$(date +%Y%m%d-%H%M%S)"
SUB_URL=""
INTERVAL=""
EXCLUDES=""
NO_START=0
usage(){ cat <<'EOF'
Usage: install-podkop-sub-sync.sh [options]
  --url URL        VPN subscription URL
  --interval SEC   Refresh interval in seconds (default 86400)
  --exclude CC     Exclude country; may be repeated (RU, UZ, ...)
  --no-start       Install/enable but do not start now
  -h, --help       Help
EOF
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --url) SUB_URL="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --exclude) EXCLUDES="${EXCLUDES}${EXCLUDES:+ }$2"; shift 2 ;;
    --no-start) NO_START=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
done
[ "$(id -u)" = "0" ] || { echo "ERROR: run as root"; exit 1; }
[ -f /etc/openwrt_release ] || { echo "ERROR: OpenWrt required"; exit 1; }
[ -f /etc/config/podkop ] || { echo "ERROR: Podkop config not found"; exit 1; }
command -v sing-box >/dev/null 2>&1 || { echo "ERROR: sing-box not found"; exit 1; }
command -v apk >/dev/null 2>&1 || { echo "ERROR: apk not found; this installer targets OpenWrt 25.12.x"; exit 1; }

need_packages=""
command -v curl >/dev/null 2>&1 || need_packages="$need_packages curl"
command -v jq >/dev/null 2>&1 || need_packages="$need_packages jq"
if [ -n "$need_packages" ]; then
  apk update
  apk add $need_packages
fi

mkdir -p "$BACKUP_DIR"
backup_if_exists(){
  src="$1"
  [ -e "$src" ] || return 0
  dst="$BACKUP_DIR$src"
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
}
for f in /usr/bin/podkop-sub-sync /usr/bin/podkop-sub-precheck /usr/bin/podkop-sub-sync-daemon /etc/init.d/podkop-sub-sync; do
  backup_if_exists "$f"
done

cat >/usr/bin/podkop-sub-precheck <<'PRECHECK'
#!/bin/ash
TAG="podkop-sub-precheck"
CFG="podkop-sub-sync"
SEC="main"
INPUT="${1:-}"
OUTPUT="${2:-}"
log(){ echo "[$(date '+%F %T')] $*"; }
die(){ log "ERROR: $*"; exit 1; }
[ -n "$INPUT" ] || die "input file not specified"
[ -n "$OUTPUT" ] || die "output file not specified"
[ -s "$INPUT" ] || die "input list is empty"
[ -r /usr/lib/podkop/sing_box_config_facade.sh ] || die "Podkop sing-box facade not found"
command -v jq >/dev/null 2>&1 || die "jq not installed"
command -v sing-box >/dev/null 2>&1 || die "sing-box not installed"
command -v curl >/dev/null 2>&1 || die "curl not installed"
. /usr/lib/podkop/sing_box_config_facade.sh
TEST_URL="$(uci -q get "${CFG}.${SEC}.precheck_url" || echo 'https://www.gstatic.com/generate_204')"
EXPECTED_CODE="$(uci -q get "${CFG}.${SEC}.precheck_http_code" || echo '204')"
TIMEOUT="$(uci -q get "${CFG}.${SEC}.precheck_timeout" || echo '7')"
CONNECT_TIMEOUT="$(uci -q get "${CFG}.${SEC}.precheck_connect_timeout" || echo '3')"
BATCH_SIZE="$(uci -q get "${CFG}.${SEC}.precheck_batch_size" || echo '6')"
BASE_PORT="$(uci -q get "${CFG}.${SEC}.precheck_base_port" || echo '39000')"
MIN_NODES="$(uci -q get "${CFG}.${SEC}.precheck_min_nodes" || echo '3')"
MIN_PERCENT="$(uci -q get "${CFG}.${SEC}.precheck_min_percent" || echo '20')"
DNS_SERVER="$(uci -q get "${CFG}.${SEC}.precheck_dns_server" || uci -q get podkop.settings.bootstrap_dns_server || echo '1.1.1.1')"
OUTBOUND_MARK=2097152
http_code_ok(){
  CODE="$1"
  if [ "$EXPECTED_CODE" = "any" ]; then case "$CODE" in 2??|3??|4??) return 0;; esac; return 1; fi
  [ "$CODE" = "$EXPECTED_CODE" ]
}
node_name(){
  LINK="$1"
  case "$LINK" in *#*) NAME="${LINK#*#}"; NAME="$(url_decode "$NAME" 2>/dev/null)"; NAME="$(printf '%s' "$NAME" | tr '\r\n\t' '   ')"; [ -n "$NAME" ] && { printf '%s\n' "$NAME"; return; };; esac
  CLEAN="$(url_strip_fragment "$(url_decode "$LINK")")"
  printf '%s %s:%s\n' "$(url_get_scheme "$CLEAN")" "$(url_get_host "$CLEAN")" "$(url_get_port "$CLEAN")"
}
set_outbound_mark(){
  printf '%s\n' "$1" | jq --arg tag "$2" --argjson mark "$OUTBOUND_MARK" '.outbounds |= map(if .tag == $tag then . + {routing_mark:$mark} else . end)'
}
strip_service_tags(){
  printf '%s\n' "$1" | jq 'if (.route.rules? != null) then .route.rules |= map(if type=="object" then del(.__service_tag) else . end) else . end | if (.dns.rules? != null) then .dns.rules |= map(if type=="object" then del(.__service_tag) else . end) else . end'
}
stop_test_singbox(){
  if [ -n "${TEST_PID:-}" ] && kill -0 "$TEST_PID" 2>/dev/null; then kill "$TEST_PID" 2>/dev/null; wait "$TEST_PID" 2>/dev/null || true; fi
  TEST_PID=""
}
TMP="$(mktemp -d /tmp/podkop-precheck.XXXXXX)" || die "cannot create temp dir"
TEST_PID=""
cleanup(){ stop_test_singbox; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
log "Checking test URL: $TEST_URL"
CONTROL_CODE="$(curl -k -sS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TIMEOUT" -o /dev/null -w '%{http_code}' "$TEST_URL" 2>/dev/null)"
if ! http_code_ok "$CONTROL_CODE"; then log "ERROR: control URL check failed (HTTP ${CONTROL_CODE:-000})"; exit 10; fi
log "Control URL is available (HTTP $CONTROL_CODE)"
TOTAL="$(wc -l <"$INPUT" | tr -d ' ')"
[ "$TOTAL" -gt 0 ] || die "no proxies to test"
: >"$OUTPUT"
GOOD=0; BAD=0; PARSER_BAD=0; GLOBAL_INDEX=0; START=1
log "Starting full proxy precheck"
log "Candidates : $TOTAL"
log "Batch size : $BATCH_SIZE"
log "Timeout    : ${TIMEOUT}s"
log "Expected   : HTTP $EXPECTED_CODE"
log ""
while [ "$START" -le "$TOTAL" ]; do
  END=$((START+BATCH_SIZE-1)); [ "$END" -gt "$TOTAL" ] && END="$TOTAL"
  BATCH="$TMP/batch-${START}.list"; MAP="$TMP/batch-${START}.map"; CONF="$TMP/batch-${START}.json"; SBLOG="$TMP/batch-${START}.log"
  sed -n "${START},${END}p" "$INPUT" >"$BATCH"; : >"$MAP"
  config='{"log":{},"dns":{},"ntp":{},"certificate":{},"endpoints":[],"inbounds":[],"outbounds":[],"route":{},"services":[],"experimental":{}}'
  config="$(sing_box_cm_configure_log "$config" false error false)"
  config="$(sing_box_cm_add_direct_outbound "$config" "precheck-direct")"
  config="$(set_outbound_mark "$config" "precheck-direct")"
  config="$(sing_box_cm_configure_dns "$config" "precheck-dns" "ipv4_only" true)"
  config="$(sing_box_cm_add_udp_dns_server "$config" "precheck-dns" "$DNS_SERVER" 53 "" "precheck-direct")"
  config="$(printf '%s\n' "$config" | jq '.route=((.route//{})+{final:"precheck-direct",auto_detect_interface:true,default_domain_resolver:"precheck-dns"}) | .route.rules=(.route.rules//[])')"
  LOCAL_INDEX=0
  while IFS= read -r LINK; do
    [ -n "$LINK" ] || continue
    GLOBAL_INDEX=$((GLOBAL_INDEX+1)); LOCAL_INDEX=$((LOCAL_INDEX+1)); PORT=$((BASE_PORT+LOCAL_INDEX))
    SECTION="precheck-${GLOBAL_INDEX}"; IN_TAG="precheck-in-${GLOBAL_INDEX}"; OUT_TAG="$(get_outbound_tag_by_section "$SECTION")"; NAME="$(node_name "$LINK")"
    NEW_CONFIG="$(sing_box_cf_add_proxy_outbound "$config" "$SECTION" "$LINK" "0")"; PARSER_RC=$?
    if [ "$PARSER_RC" -ne 0 ] || [ -z "$NEW_CONFIG" ]; then log "[$GLOBAL_INDEX/$TOTAL] PARSER FAIL  $NAME"; PARSER_BAD=$((PARSER_BAD+1)); BAD=$((BAD+1)); continue; fi
    config="$NEW_CONFIG"
    config="$(set_outbound_mark "$config" "$OUT_TAG")"
    config="$(sing_box_cf_add_mixed_inbound_and_route_rule "$config" "$IN_TAG" "127.0.0.1" "$PORT" "$OUT_TAG")"
    printf '%s\t%s\t%s\n' "$PORT" "$GLOBAL_INDEX" "$LINK" >>"$MAP"
  done <"$BATCH"
  if [ ! -s "$MAP" ]; then START=$((END+1)); continue; fi
  config="$(strip_service_tags "$config")"; printf '%s\n' "$config" >"$CONF"
  CHECK="$(sing-box check -c "$CONF" 2>&1)"; CHECK_RC=$?
  if [ "$CHECK_RC" -ne 0 ]; then log "ERROR: temporary config failed validation: $CHECK"; cp "$CONF" /tmp/podkop-precheck-broken.json; exit 11; fi
  sing-box run -c "$CONF" >"$SBLOG" 2>&1 & TEST_PID=$!; sleep 1
  if ! kill -0 "$TEST_PID" 2>/dev/null; then log "ERROR: temporary sing-box exited"; tail -50 "$SBLOG"; exit 12; fi
  TAB="$(printf '\t')"
  while IFS="$TAB" read -r PORT INDEX LINK; do
    [ -n "$LINK" ] || continue
    NAME="$(node_name "$LINK")"
    RESULT="$(curl -k -sS -x "http://127.0.0.1:${PORT}" --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TIMEOUT" -o /dev/null -w '%{http_code} %{time_total}' "$TEST_URL" 2>/dev/null)"; CURL_RC=$?
    CODE="$(echo "$RESULT" | awk '{print $1}')"; TIME="$(echo "$RESULT" | awk '{print $2}')"; [ -n "$CODE" ] || CODE="000"
    if [ "$CURL_RC" -eq 0 ] && http_code_ok "$CODE"; then
      MS="$(awk -v t="${TIME:-0}" 'BEGIN{printf "%.0f",t*1000}')"; printf '%s\n' "$LINK" >>"$OUTPUT"; GOOD=$((GOOD+1)); log "[$INDEX/$TOTAL] OK   ${MS}ms  $NAME"
    else
      BAD=$((BAD+1)); log "[$INDEX/$TOTAL] FAIL HTTP=${CODE} rc=${CURL_RC}  $NAME"
    fi
  done <"$MAP"
  stop_test_singbox; START=$((END+1))
done
PERCENT=$((GOOD*100/TOTAL)); REQUIRED_NODES="$MIN_NODES"; [ "$TOTAL" -lt "$REQUIRED_NODES" ] && REQUIRED_NODES="$TOTAL"
log ""; log "========================================"; log "Proxy precheck finished"; log "Total       : $TOTAL"; log "Working     : $GOOD"; log "Failed      : $BAD"; log "Parser fail : $PARSER_BAD"; log "Success     : ${PERCENT}%"; log "========================================"
[ "$GOOD" -ge "$REQUIRED_NODES" ] || { log "ERROR: only $GOOD nodes passed; minimum $REQUIRED_NODES"; exit 20; }
[ "$PERCENT" -ge "$MIN_PERCENT" ] || { log "ERROR: only ${PERCENT}% passed; minimum ${MIN_PERCENT}%"; exit 21; }
exit 0
PRECHECK

cat >/usr/bin/podkop-sub-sync <<'SYNC'
#!/bin/ash
TAG="podkop-sub-sync"; CFG="podkop-sub-sync"; SEC="main"; STATE_DIR="/etc"; LOCK="/var/lock/podkop-sub-sync.lock"
log(){ echo "[$(date '+%F %T')] $*"; }
need(){ command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing command: $1"; exit 1; }; }
country_flag_encoded(){ CODE="$(echo "$1"|tr '[:lower:]' '[:upper:]')"; [ "${#CODE}" -eq 2 ] || return 1; C1="${CODE%?}"; C2="${CODE#?}"; I1="$(awk -v c="$C1" 'BEGIN{n=index("ABCDEFGHIJKLMNOPQRSTUVWXYZ",c);if(!n)exit 1;print n-1}')"||return 1; I2="$(awk -v c="$C2" 'BEGIN{n=index("ABCDEFGHIJKLMNOPQRSTUVWXYZ",c);if(!n)exit 1;print n-1}')"||return 1; printf '%%F0%%9F%%87%%%02X%%F0%%9F%%87%%%02X\n' $((0xA6+I1)) $((0xA6+I2)); }
count_protocol(){ grep -c "^$1://" "$2" 2>/dev/null || true; }
for c in curl uci base64 sha256sum sing-box grep sed sort gzip awk tr; do need "$c"; done
ENABLED="$(uci -q get ${CFG}.${SEC}.enabled||echo 0)"; [ "$ENABLED" = 1 ] || { log "Sync disabled"; exit 0; }
URL="$(uci -q get ${CFG}.${SEC}.url||true)"; TARGET="$(uci -q get ${CFG}.${SEC}.target||echo main)"; UA="$(uci -q get ${CFG}.${SEC}.user_agent||echo podkop-sub-sync/1.2)"; SEND_HWID="$(uci -q get ${CFG}.${SEC}.send_hwid||echo 0)"; HWID="$(uci -q get ${CFG}.${SEC}.hwid||true)"; ALLOW_XHTTP="$(uci -q get ${CFG}.${SEC}.allow_xhttp||echo 0)"
ENABLE_VLESS="$(uci -q get ${CFG}.${SEC}.enable_vless||echo 1)"; ENABLE_TROJAN="$(uci -q get ${CFG}.${SEC}.enable_trojan||echo 1)"; ENABLE_SS="$(uci -q get ${CFG}.${SEC}.enable_ss||echo 1)"; EXCLUDE_COUNTRIES="$(uci -q get ${CFG}.${SEC}.exclude_country||true)"
[ -n "$URL" ] || { log "ERROR: subscription URL empty"; exit 2; }; uci -q get "podkop.${TARGET}" >/dev/null 2>&1 || { log "ERROR: podkop section $TARGET missing"; exit 2; }
PROTO_RE=""; [ "$ENABLE_VLESS" = 1 ] && PROTO_RE=vless; [ "$ENABLE_TROJAN" = 1 ] && { [ -n "$PROTO_RE" ] && PROTO_RE="$PROTO_RE|trojan" || PROTO_RE=trojan; }; [ "$ENABLE_SS" = 1 ] && { [ -n "$PROTO_RE" ] && PROTO_RE="$PROTO_RE|ss" || PROTO_RE=ss; }; [ -n "$PROTO_RE" ] || { log "ERROR: all protocols disabled"; exit 2; }
log "Enabled protocols: $PROTO_RE"
mkdir "$LOCK" 2>/dev/null || { log "Another updater is already running"; exit 0; }; TMP="$(mktemp -d /tmp/podkop-sub.XXXXXX)" || exit 1; cleanup(){ rm -rf "$TMP"; rmdir "$LOCK" 2>/dev/null; }; trap cleanup EXIT INT TERM
if [ "$SEND_HWID" = 1 ] && [ -z "$HWID" ]; then if [ -r /sys/class/net/br-lan/address ]; then HWID="$(tr -d ':' </sys/class/net/br-lan/address)"; elif [ -r /etc/machine-id ]; then HWID="$(cat /etc/machine-id)"; else HWID="$(uname -n|sha256sum|awk '{print $1}')"; fi; uci set ${CFG}.${SEC}.hwid="$HWID"; uci commit "$CFG"; fi
RAW="$TMP/sub.raw"; log "Downloading subscription..."; set -- -fsSL --compressed --connect-timeout 10 --max-time 30 --retry 2 -A "$UA"; [ "$SEND_HWID" = 1 ] && set -- "$@" -H "X-HWID: $HWID" -H "X-Device-ID: $HWID"; curl "$@" "$URL" -o "$RAW" || { log "ERROR: download failed"; exit 3; }; [ -s "$RAW" ] || exit 3
PAYLOAD="$TMP/payload"; if gzip -t "$RAW" >/dev/null 2>&1; then gzip -dc "$RAW" >"$PAYLOAD" || exit 3; else cp "$RAW" "$PAYLOAD"; fi
TEXT="$PAYLOAD"; if ! grep -Eq '(vless|trojan|ss)://' "$PAYLOAD"; then log "Trying base64 decode"; COMPACT="$TMP/base64"; DECODED="$TMP/decoded"; tr -d '\r\n\t ' <"$PAYLOAD" >"$COMPACT"; base64 -d "$COMPACT" >"$DECODED" 2>/dev/null || { log "ERROR: unknown subscription format"; exit 4; }; if gzip -t "$DECODED" >/dev/null 2>&1; then TEXT="$TMP/decoded-gzip"; gzip -dc "$DECODED" >"$TEXT" || exit 4; else TEXT="$DECODED"; fi; fi
LIST="$TMP/proxies.list"; grep -Eo "(${PROTO_RE})://[^[:space:]]+" "$TEXT"|sed 's/\r$//'|sort -u >"$LIST"; COUNT="$(wc -l <"$LIST"|tr -d ' ')"; [ "$COUNT" -gt 0 ] || exit 4; log "Found $COUNT proxies after protocol filter"
XHTTP="$(grep -Ec '([?&])type=xhttp([&#]|$)' "$LIST" 2>/dev/null||true)"; if [ "$XHTTP" -gt 0 ] && [ "$ALLOW_XHTTP" != 1 ]; then log "Found $XHTTP XHTTP proxies; filtering them"; F="$TMP/xhttp.filtered"; grep -Eiv '([?&])type=xhttp([&#]|$)' "$LIST" >"$F"||true; mv "$F" "$LIST"; fi
for COUNTRY in $EXCLUDE_COUNTRIES; do COUNTRY="$(echo "$COUNTRY"|tr '[:lower:]' '[:upper:]')"; FLAG="$(country_flag_encoded "$COUNTRY")" || continue; BEFORE="$(wc -l <"$LIST"|tr -d ' ')"; F="$TMP/country-${COUNTRY}.filtered"; grep -viF "$FLAG" "$LIST" >"$F"||true; mv "$F" "$LIST"; AFTER="$(wc -l <"$LIST"|tr -d ' ')"; log "Country $COUNTRY excluded: $((BEFORE-AFTER)) proxies"; done
PRECHECK_ENABLED="$(uci -q get ${CFG}.${SEC}.precheck_enabled||echo 0)"; if [ "$PRECHECK_ENABLED" = 1 ]; then log "Running real proxy availability precheck..."; PRECHECKED="$TMP/proxies.prechecked"; /usr/bin/podkop-sub-precheck "$LIST" "$PRECHECKED"; RC=$?; [ "$RC" -eq 0 ] || { log "ERROR: proxy precheck failed (code $RC); current config unchanged"; exit 4; }; [ -s "$PRECHECKED" ] || exit 4; mv "$PRECHECKED" "$LIST"; log "Precheck accepted $(wc -l <"$LIST"|tr -d ' ') working proxies"; fi
COUNT="$(wc -l <"$LIST"|tr -d ' ')"; [ "$COUNT" -gt 0 ] || exit 4; log "Final proxy list:"; log "  VLESS : $(count_protocol vless "$LIST")"; log "  Trojan: $(count_protocol trojan "$LIST")"; log "  SS    : $(count_protocol ss "$LIST")"; log "  Total : $COUNT"
HASH="$(sha256sum "$LIST"|awk '{print $1}')"; STATE="${STATE_DIR}/podkop-sub-sync-${TARGET}.sha256"; if [ -r "$STATE" ] && [ "$HASH" = "$(cat "$STATE")" ]; then log "Working proxy list unchanged ($COUNT proxies)"; exit 0; fi; log "Working proxy list changed: $COUNT proxies"
BACKUP="$TMP/podkop.backup"; cp /etc/config/podkop "$BACKUP" || exit 5; rollback(){ log "ERROR: new config failed; restoring backup"; cp "$BACKUP" /etc/config/podkop; /etc/init.d/podkop restart >/dev/null 2>&1; exit 5; }
uci set podkop.${TARGET}.connection_type=proxy; uci set podkop.${TARGET}.proxy_config_type=urltest; uci -q delete podkop.${TARGET}.urltest_proxy_links; ADDED=0; while IFS= read -r LINK; do [ -n "$LINK" ] || continue; uci add_list podkop.${TARGET}.urltest_proxy_links="$LINK" || rollback; ADDED=$((ADDED+1)); done <"$LIST"; uci commit podkop || rollback; log "Written $ADDED proxy links to Podkop"; log "Restarting Podkop..."; /etc/init.d/podkop restart || rollback
SINGCONF="$(uci -q get podkop.settings.config_path||echo /etc/sing-box/config.json)"; log "Waiting for Podkop/sing-box configuration to become ready..."; CHECK_OK=0; WAITED=0; CHECK_OUT=""; while [ "$WAITED" -lt 60 ]; do [ -s "$SINGCONF" ] || { sleep 1; WAITED=$((WAITED+1)); continue; }; CHECK_OUT="$(sing-box check -c "$SINGCONF" 2>&1)"; RC=$?; [ "$RC" -eq 0 ] && { CHECK_OK=1; break; }; echo "$CHECK_OUT"|grep -qE 'rule-set.*no such file or directory|/tmp/sing-box/rulesets/.*no such file or directory' || break; [ $((WAITED%5)) -eq 0 ] && log "Waiting for Podkop rulesets... ${WAITED}s"; sleep 1; WAITED=$((WAITED+1)); done
[ "$CHECK_OK" = 1 ] || { log "ERROR: sing-box validation failed"; echo "$CHECK_OUT"; [ -s "$SINGCONF" ] && cp "$SINGCONF" /tmp/podkop-sub-broken.json; rollback; }; log "sing-box configuration validated after ${WAITED}s"; PWAIT=0; while ! pidof sing-box >/dev/null 2>&1; do PWAIT=$((PWAIT+1)); [ "$PWAIT" -lt 20 ] || rollback; sleep 1; done; sing-box check -c "$SINGCONF" >/dev/null 2>&1 || rollback; echo "$HASH" >"$STATE"; log "Update successful: $COUNT proxies"; exit 0
SYNC

cat >/usr/bin/podkop-sub-sync-daemon <<'DAEMON'
#!/bin/ash
while :; do
  echo "[$(date '+%F %T')] Starting subscription sync"
  /usr/bin/podkop-sub-sync
  RC=$?
  INTERVAL="$(uci -q get podkop-sub-sync.main.interval)"
  RETRY_INTERVAL="$(uci -q get podkop-sub-sync.main.retry_interval)"
  case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=86400;; esac
  case "$RETRY_INTERVAL" in ''|*[!0-9]*) RETRY_INTERVAL=900;; esac
  [ "$INTERVAL" -lt 60 ] && INTERVAL=60
  [ "$RETRY_INTERVAL" -lt 60 ] && RETRY_INTERVAL=60
  if [ "$RC" -eq 0 ]; then
    echo "[$(date '+%F %T')] Subscription sync completed successfully"
    echo "[$(date '+%F %T')] Next sync in ${INTERVAL}s"
    sleep "$INTERVAL"
  else
    echo "[$(date '+%F %T')] Subscription sync failed with code $RC"
    echo "[$(date '+%F %T')] Retry in ${RETRY_INTERVAL}s"
    sleep "$RETRY_INTERVAL"
  fi
done
DAEMON

cat >/etc/init.d/podkop-sub-sync <<'INIT'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=10
start_service(){
  enabled="$(uci -q get podkop-sub-sync.main.enabled)"
  [ "$enabled" = "1" ] || return 0
  procd_open_instance
  procd_set_param command /bin/ash /usr/bin/podkop-sub-sync-daemon
  procd_set_param respawn 3600 5 5
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
service_triggers(){ procd_add_reload_trigger podkop-sub-sync; }
INIT

chmod 755 /usr/bin/podkop-sub-sync /usr/bin/podkop-sub-precheck /usr/bin/podkop-sub-sync-daemon /etc/init.d/podkop-sub-sync

if [ ! -f /etc/config/podkop-sub-sync ]; then
cat >/etc/config/podkop-sub-sync <<'CONF'
config sync 'main'
        option enabled '1'
        option url ''
        option target 'main'
        option interval '86400'
        option retry_interval '900'
        option user_agent 'podkop-sub-sync/1.2'
        option send_hwid '0'
        option allow_xhttp '0'
        option enable_vless '1'
        option enable_trojan '1'
        option enable_ss '1'
        option precheck_enabled '1'
        option precheck_url 'https://www.gstatic.com/generate_204'
        option precheck_http_code '204'
        option precheck_connect_timeout '3'
        option precheck_timeout '7'
        option precheck_batch_size '6'
        option precheck_base_port '39000'
        option precheck_min_nodes '3'
        option precheck_min_percent '20'
CONF
else
  echo "Preserving existing /etc/config/podkop-sub-sync"
  uci -q get podkop-sub-sync.main.retry_interval >/dev/null || uci set podkop-sub-sync.main.retry_interval='900'
fi

[ -n "$SUB_URL" ] && uci set podkop-sub-sync.main.url="$SUB_URL"
if [ -n "$INTERVAL" ]; then case "$INTERVAL" in ''|*[!0-9]*) echo "ERROR: interval must be seconds"; exit 2;; esac; uci set podkop-sub-sync.main.interval="$INTERVAL"; fi
if [ -n "$EXCLUDES" ]; then uci -q delete podkop-sub-sync.main.exclude_country || true; for cc in $EXCLUDES; do cc="$(echo "$cc"|tr '[:lower:]' '[:upper:]')"; case "$cc" in [A-Z][A-Z]) ;; *) echo "ERROR: invalid country $cc"; exit 2;; esac; uci add_list podkop-sub-sync.main.exclude_country="$cc"; done; fi
uci commit podkop-sub-sync

for f in /usr/bin/podkop-sub-sync /usr/bin/podkop-sub-precheck /usr/bin/podkop-sub-sync-daemon /etc/init.d/podkop-sub-sync; do /bin/ash -n "$f" || { echo "ERROR: syntax error in $f"; exit 1; }; done

/etc/init.d/podkop-sub-sync enable
CONFIGURED_URL="$(uci -q get podkop-sub-sync.main.url||true)"
if [ "$NO_START" = 1 ]; then
  echo "Installed and enabled; not started (--no-start)."
elif [ -z "$CONFIGURED_URL" ]; then
  echo "Installed, but URL is empty. Set podkop-sub-sync.main.url and start the service."
else
  /etc/init.d/podkop-sub-sync stop >/dev/null 2>&1 || true
  /etc/init.d/podkop-sub-sync start
fi

echo "Installation complete. Backup: $BACKUP_DIR"
echo "Check: ubus call service list '{\"name\":\"podkop-sub-sync\"}'"
echo "Logs : logread | grep podkop-sub-sync | tail -100"
