#!/usr/bin/env bash
# =====================================================================
#  HCR Server (HTTP Custom Relay) - instalador automatico
#
#  Uso:
#    bash <(curl -fsSL https://raw.githubusercontent.com/USUARIO/REPO/main/hcr.sh)
#
#  Opciones:
#    --port N      puerto (por defecto el primero libre de 8080 8880 8081 2082 2086)
#    --frame N     max-download-frame (por defecto 2048)
#    --poll N      download-poll-timeout en segundos (por defecto 3)
#    --force       instalar aunque la maquina tenga Veltrix
#    --uninstall   desinstalar y borrar todo
# =====================================================================

set -euo pipefail

# ---------------- editar al subir el repo ----------------------------
REPO_RAW="${HCR_REPO:-https://raw.githubusercontent.com/USUARIO/REPO/main}"
# sha256 de hcr-server. Si subis una version nueva: sha256sum hcr-server
BIN_SHA256="68a66ed49750965680315a60ce05260cdbb77c2b86b3a80938844cb4855fa085"
# ---------------------------------------------------------------------

DEST="/opt/hcr"
UNIT="${DEST}/hcr-server.service"
LOG="/var/log/hcr-install.log"
CANDIDATES="8080 8880 8081 2082 2086"

PORT=""
FRAME="2048"
POLL="3s"
FORCE="false"
ACTION="install"
TMP=""

die()  { printf '\n\033[31mERROR:\033[0m %b\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }

usage() {
	cat <<'EOF'
HCR Server - instalador automatico

  bash <(curl -fsSL URL/hcr.sh) [opciones]

  --port N      puerto (por defecto el primero libre de 8080 8880 8081 2082 2086)
  --frame N     max-download-frame (por defecto 2048)
  --poll N      download-poll-timeout en segundos (por defecto 3)
  --force       instalar aunque la maquina tenga Veltrix
  --uninstall   desinstalar y borrar todo
EOF
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
			--port|--frame|--poll)
				[ $# -ge 2 ] || die "$1 necesita un valor"
				case "$1" in
					--port)  PORT="$2" ;;
					--frame) FRAME="$2" ;;
					--poll)  POLL="$2" ;;
				esac
				shift 2 ;;
			--force)     FORCE="true"; shift ;;
			--uninstall) ACTION="uninstall"; shift ;;
			-h|--help)   usage; exit 0 ;;
			*) die "opcion desconocida: $1 (usa --help)" ;;
		esac
	done
	if [ -n "$PORT" ]; then
		[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port invalido: $PORT"
	fi
	[[ "$FRAME" =~ ^[0-9]+$ ]] && [ "$FRAME" -ge 256 ] || die "--frame invalido: $FRAME"
	if [[ "$POLL" =~ ^[0-9]+$ ]]; then POLL="${POLL}s"; fi
	[[ "$POLL" =~ ^[0-9]+(ms|s)$ ]] || die "--poll invalido: $POLL"
}

# --- puertos ---------------------------------------------------------

# ocupado por algo que no sea hcr-server
port_taken() {
	ss -ltnp 2>/dev/null | awk -v p="$1" '
		NR>1 { k=split($4,a,":"); if (a[k]==p && $NF !~ /"hcr-server"/) f=1 }
		END { exit !f }'
}

hcr_on() {
	ss -ltnp 2>/dev/null | awk -v p="$1" '
		NR>1 { k=split($4,a,":"); if (a[k]==p && $NF ~ /"hcr-server"/) f=1 }
		END { exit !f }'
}

port_owner() {
	ss -ltnp 2>/dev/null | awk -v p="$1" '
		NR>1 { k=split($4,a,":"); if (a[k]==p) print "    " $4 "  " $NF }'
}

ports_of() {
	ss -ltnp 2>/dev/null | awk -v n="\"$1\"" '
		NR>1 && index($NF,n) { k=split($4,a,":"); print a[k] }' | sort -un
}

current_port() {
	[ -f "$UNIT" ] || return 0
	awk 'match($0, /--listen :[0-9]+/) { print substr($0, RSTART+10, RLENGTH-10); exit }' "$UNIT"
}

# --- ssh -------------------------------------------------------------

ssh_ok() {
	local b
	b=$(timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1 && head -c 4 <&3" 2>/dev/null || true)
	[ "$b" = "SSH-" ]
}

# 22 primero (cubre sshd por socket de systemd), despues sshd y dropbear
detect_ssh() {
	local p proc
	if ssh_ok 22; then echo 22; return 0; fi
	for proc in sshd dropbear; do
		for p in $(ports_of "$proc"); do
			if ssh_ok "$p"; then echo "$p"; return 0; fi
		done
	done
	return 1
}

# --- instalacion -----------------------------------------------------

fetch() {
	curl -fsSL --retry 3 --connect-timeout 10 -o "$2" "${REPO_RAW}/$1" ||
		die "no pude bajar $1 desde ${REPO_RAW}"
}

patch_installer() {
	local f="$1" ssh_port="$2"
	sed -i \
		-e "s|^MAX_DOWNLOAD_FRAME=.*|MAX_DOWNLOAD_FRAME=\"${FRAME}\"|" \
		-e "s|^DOWNLOAD_POLL_TIMEOUT=.*|DOWNLOAD_POLL_TIMEOUT=\"${POLL}\"|" \
		-e "s|--target 127\.0\.0\.1:[0-9]* |--target 127.0.0.1:${ssh_port} |" \
		-e '/--max-connections/! s|--download-poll-timeout ${DOWNLOAD_POLL_TIMEOUT}$|& --max-sessions 1000 --max-sessions-per-ip 1000 --max-connections 8192|' \
		-e 's|^LimitNOFILE=.*|LimitNOFILE=65535|' \
		-e 's|^MemoryMax=.*|MemoryMax=1G|' \
		"$f"
	grep -q "^MAX_DOWNLOAD_FRAME=\"${FRAME}\"$" "$f" &&
	grep -q "^DOWNLOAD_POLL_TIMEOUT=\"${POLL}\"$" "$f" &&
	grep -q -- "--target 127.0.0.1:${ssh_port} " "$f" &&
	grep -q -- "--max-connections 8192" "$f" &&
	grep -q '^LimitNOFILE=65535$' "$f" &&
	grep -q '^MemoryMax=1G$' "$f" ||
		die "no pude aplicar la configuracion al install.sh (puede que el dev lo haya cambiado)"
}

open_firewall() {
	local st
	if command -v ufw >/dev/null 2>&1; then
		st=$(ufw status 2>/dev/null || true)
		if [[ "$st" == *"Status: active"* ]]; then
			if ufw allow "${PORT}/tcp" >/dev/null 2>&1; then
				ok "ufw: puerto $PORT habilitado"
			else
				warn "no pude abrir el $PORT en ufw, hacelo a mano"
			fi
		fi
	fi
	if command -v iptables >/dev/null 2>&1; then
		st=$(iptables -S INPUT 2>/dev/null || true)
		if [[ "$st" == *"-P INPUT DROP"* ]]; then
			warn "iptables tiene politica DROP en INPUT: puede que tengas que abrir el $PORT a mano"
		fi
	fi
}

public_ip() {
	local u ip
	for u in https://api.ipify.org https://ifconfig.me; do
		ip=$(curl -fsS --max-time 5 "$u" 2>/dev/null || true)
		if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$ip"; return 0; fi
	done
	hostname -I 2>/dev/null | awk '{print $1}'
}

do_uninstall() {
	info "Desinstalando HCR"
	if [ -x "$DEST/install.sh" ]; then "$DEST/install.sh" --uninstall || true; fi
	systemctl disable --now hcr-server.service >/dev/null 2>&1 || true
	if [ -L /etc/systemd/system/hcr-server.service ]; then rm -f /etc/systemd/system/hcr-server.service; fi
	rm -rf "$DEST"
	systemctl daemon-reload
	systemctl reset-failed hcr-server.service >/dev/null 2>&1 || true
	ok "HCR desinstalado y borrado de $DEST"
}

main() {
	parse_args "$@"
	[ "$(id -u)" -eq 0 ] || die "hay que correrlo como root"
	cd /
	mkdir -p "$(dirname "$LOG")"
	exec > >(tee -a "$LOG") 2>&1
	echo "---- $(date '+%F %T') hcr.sh ${ACTION} ----"

	if [ "$ACTION" = "uninstall" ]; then do_uninstall; exit 0; fi

	info "Chequeos"
	case "$REPO_RAW" in *USUARIO/REPO*) die "falta configurar REPO_RAW en el script" ;; esac
	[ "$(uname -m)" = "x86_64" ] || die "el binario es para x86_64 y esta maquina es $(uname -m)"
	if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
		die "esta maquina no usa systemd"
	fi
	local c
	for c in curl ss sha256sum timeout; do
		command -v "$c" >/dev/null 2>&1 || die "falta '$c' (apt install -y curl iproute2 coreutils)"
	done

	if [ -f /etc/proxyvt/config.json ] && [ "$FORCE" != "true" ]; then
		die "esta maquina tiene Veltrix, que ya trae HCR integrado: no hace falta este instalador.\n  Si anda lento: \"max_download_frame\": 2048 en /etc/proxyvt/config.json y systemctl restart vtproxy\n  Para instalarlo igual en otro puerto: agregar --force"
	fi

	local ssh_port
	ssh_port=$(detect_ssh) || die "no encontre ningun SSH respondiendo en esta maquina (sshd o dropbear)"
	ok "SSH local en el puerto $ssh_port"

	local existing p
	existing=$(current_port)
	if [ -z "$PORT" ]; then
		if [ -n "$existing" ]; then
			PORT="$existing"
		else
			for p in $CANDIDATES; do
				if ! port_taken "$p"; then PORT="$p"; break; fi
			done
		fi
	fi
	[ -n "$PORT" ] || die "no hay puerto libre entre $CANDIDATES. Elegi uno con --port N"
	if port_taken "$PORT"; then
		die "el puerto $PORT esta ocupado por:\n$(port_owner "$PORT")\n  Elegi otro con --port N"
	fi
	ok "Puerto $PORT libre"
	if [ -n "$existing" ]; then info "Ya habia una instalacion (puerto $existing): se actualiza"; fi

	info "Descargando"
	TMP=$(mktemp -d)
	trap 'rm -rf "$TMP"' EXIT
	fetch hcr-server "$TMP/hcr-server"
	fetch install.sh "$TMP/install.sh"
	echo "${BIN_SHA256}  $TMP/hcr-server" | sha256sum -c --status - ||
		die "el binario descargado no coincide con el sha256 esperado (corrupto o cambiado)"
	grep -q '^render_unit()' "$TMP/install.sh" || die "el install.sh descargado no es el esperado"
	patch_installer "$TMP/install.sh" "$ssh_port"
	ok "Archivos verificados"

	info "Instalando"
	if [ -n "$existing" ]; then systemctl stop hcr-server.service >/dev/null 2>&1 || true; fi
	install -d -o root -g root -m 755 "$DEST"
	install -o root -g root -m 755 "$TMP/hcr-server" "$DEST/hcr-server"
	install -o root -g root -m 755 "$TMP/install.sh" "$DEST/install.sh"
	local ver
	ver=$("$DEST/hcr-server" -version 2>&1 || true)
	case "$ver" in
		"hcr-server version"*) ok "$ver" ;;
		*) die "el binario no arranca en esta maquina: $ver" ;;
	esac
	(cd "$DEST" && ./install.sh --port "$PORT" --transport plain) ||
		die "fallo la instalacion del servicio. Revisa: journalctl -u hcr-server -n 30"

	local _
	for _ in $(seq 1 15); do
		if hcr_on "$PORT"; then break; fi
		sleep 1
	done
	hcr_on "$PORT" || die "el servicio no quedo escuchando en $PORT. Revisa: journalctl -u hcr-server -n 30"
	ok "Escuchando en $PORT"

	open_firewall

	local ip
	ip=$(public_ip)
	printf '\n\033[32m==========================================\033[0m\n'
	printf '  HCR listo\n\n'
	printf '  Host:    %s\n' "${ip:-IP de la VPS}"
	printf '  Puerto:  %s\n' "$PORT"
	printf '  Modo:    HCR, sin TLS\n'
	printf '  App:     HTTP Custom 7.10.12 (808) o superior\n'
	printf '\033[32m==========================================\033[0m\n\n'
	echo "Si no conecta desde afuera, el proveedor puede estar filtrando el puerto $PORT:"
	echo "habilitalo en el panel de la VPS (Firewall / Security Group)."
	echo "Log: $LOG"
}

if [ "${HCR_NO_MAIN:-}" != "1" ]; then
	main "$@"
fi
