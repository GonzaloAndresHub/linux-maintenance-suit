sudo bash << 'EOF'
set -euo pipefail

trap 'echo ""; read -rp "  Presiona Enter para cerrar..." _' EXIT

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
section() { echo -e "\n${BOLD}${GREEN}══════════════════════════════════════${NC}";
            echo -e "${BOLD}  $*${NC}";
            echo -e "${BOLD}${GREEN}══════════════════════════════════════${NC}"; }

freed_space() {
    local before=$1 after
    after=$(df / --output=used -k | tail -1)
    local diff=$(( before - after ))
    if (( diff > 0 )); then
        ok "Espacio liberado: ~$(( diff / 1024 )) MB"
    fi
}

DISK_BEFORE=$(df / --output=used -k | tail -1)

section "1. Actualizar lista de paquetes"
apt-get update -qq && ok "Repositorios actualizados"

section "2. Paquetes rotos o inconsistentes"
info "Configurando paquetes pendientes..."
dpkg --configure -a
info "Reparando dependencias rotas..."
apt-get install -f -y -qq && ok "Dependencias reparadas"
dpkg --audit 2>/dev/null && ok "No se encontraron paquetes dañados críticos"

section "3. Paquetes huérfanos y no necesarios"
info "Eliminando paquetes que ya no son necesarios..."
apt-get autoremove --purge -y -qq
freed_space $DISK_BEFORE

section "4. Caché de APT"
DISK_BEFORE=$(df / --output=used -k | tail -1)
info "Limpiando paquetes .deb descargados..."
apt-get clean -qq
apt-get autoclean -qq
ok "Caché de APT limpiada"
freed_space $DISK_BEFORE

section "5. Repositorios PPA duplicados o desactualizados"
DISK_BEFORE=$(df / --output=used -k | tail -1)
if command -v add-apt-repository &>/dev/null; then
    DUPLICATES=$(find /etc/apt/sources.list.d/ -name "*.list" -print0 \
        | xargs -0 grep -h "^deb " 2>/dev/null \
        | sort | uniq -d || true)
    if [[ -n "$DUPLICATES" ]]; then
        warn "Entradas duplicadas en sources.list.d:"
        echo "$DUPLICATES"
    else
        ok "No se encontraron repositorios duplicados"
    fi
else
    warn "add-apt-repository no disponible; revisión omitida"
fi
info "Buscando repositorios con errores 404..."
FAILED_REPOS=$(apt-get update 2>&1 | grep -E "^Err.*404|^W.*NO_PUBKEY" || true)
if [[ -n "$FAILED_REPOS" ]]; then
    warn "Repositorios con problemas (revísalos manualmente):"
    echo "$FAILED_REPOS"
else
    ok "Todos los repositorios responden correctamente"
fi

section "6. Kernels antiguos"
DISK_BEFORE=$(df / --output=used -k | tail -1)
CURRENT_KERNEL=$(uname -r)
info "Kernel activo: $CURRENT_KERNEL"
OLD_KERNELS=$(dpkg --list 'linux-image-*' 'linux-headers-*' 'linux-modules-*' 2>/dev/null \
    | awk '/^ii/ {print $2}' \
    | grep -v "$CURRENT_KERNEL" \
    | grep -v "linux-image-generic" \
    | grep -v "linux-headers-generic" \
    || true)
if [[ -n "$OLD_KERNELS" ]]; then
    info "Kernels a eliminar:"
    echo "$OLD_KERNELS"
    echo "$OLD_KERNELS" | xargs apt-get purge -y -qq
    ok "Kernels antiguos eliminados"
    freed_space $DISK_BEFORE
else
    ok "No se encontraron kernels antiguos para eliminar"
fi

section "7. Caché de usuario"
DISK_BEFORE=$(df / --output=used -k | tail -1)
info "Limpiando caché de miniaturas..."
find /home/*/.cache/thumbnails -type f -delete 2>/dev/null || true
find /root/.cache/thumbnails   -type f -delete 2>/dev/null || true
info "Limpiando caché de aplicaciones (>30 días sin uso)..."
find /home/*/.cache -type f -atime +30 -delete 2>/dev/null || true
ok "Caché de usuario limpiada"
freed_space $DISK_BEFORE

section "8. Logs del sistema"
DISK_BEFORE=$(df / --output=used -k | tail -1)
info "Truncando logs de journald (últimos 7 días / máx 100 MB)..."
journalctl --vacuum-time=7d   --quiet 2>/dev/null || true
journalctl --vacuum-size=100M --quiet 2>/dev/null || true
info "Comprimiendo logs de /var/log (>7 días sin acceso)..."
find /var/log -type f -name "*.log" -atime +7 ! -name "*.gz" \
    -exec gzip -9 {} \; 2>/dev/null || true
info "Eliminando logs rotados >30 días..."
find /var/log -type f -name "*.gz" -mtime +30 -delete 2>/dev/null || true
ok "Logs comprimidos y limpiados"
freed_space $DISK_BEFORE

section "9. Archivos temporales"
DISK_BEFORE=$(df / --output=used -k | tail -1)
info "Limpiando /tmp (archivos >24 h)..."
find /tmp -type f -atime +1 -delete 2>/dev/null || true
find /tmp -type d -empty   -delete 2>/dev/null || true
info "Limpiando /var/tmp (archivos >7 días)..."
find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
ok "Archivos temporales eliminados"
freed_space $DISK_BEFORE

section "10. Limpiar RAM — caché del sistema"
RAM_BEFORE=$(free -m | awk '/^Mem:/ {print $7}')
info "Memoria disponible antes: ${RAM_BEFORE} MB"
sync
info "Liberando page cache, dentries e inodes..."
echo 3 > /proc/sys/vm/drop_caches
RAM_AFTER=$(free -m | awk '/^Mem:/ {print $7}')
GAINED=$(( RAM_AFTER - RAM_BEFORE ))
ok "Memoria disponible después: ${RAM_AFTER} MB  (+${GAINED} MB recuperados)"

section "11. Snap — revisiones antiguas"
if command -v snap &>/dev/null; then
    DISK_BEFORE=$(df / --output=used -k | tail -1)
    info "Eliminando revisiones antiguas de snaps..."
    snap list --all 2>/dev/null \
        | awk '/disabled/{print $1, $3}' \
        | while read SNAPNAME REV; do
            snap remove "$SNAPNAME" --revision="$REV" 2>/dev/null && \
                ok "Snap eliminado: $SNAPNAME rev.$REV" || true
        done
    freed_space $DISK_BEFORE
else
    info "Snap no está instalado, omitiendo"
fi

section "12. Resumen final"
DISK_AFTER=$(df / --output=used -k | tail -1)
TOTAL_FREED=$(( DISK_BEFORE - DISK_AFTER ))
echo ""
echo -e "${BOLD}  Espacio total aproximado liberado: ~$(( TOTAL_FREED / 1024 )) MB${NC}"
echo -e "${BOLD}  Uso de disco actual:${NC}"
df -h / /home 2>/dev/null | tail -n +1
echo ""
echo -e "${BOLD}  Estado de RAM:${NC}"
free -h
echo ""
ok "¡Limpieza completada exitosamente!"

EOF
