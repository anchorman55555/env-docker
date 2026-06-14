#!/usr/bin/env bash
step "STEP 8/8 -- Verification"

cd "${PROJECT_DIR}"
FAILED=0

# ── Containers ────────────────────────────────────────────────────────────
echo
ok "--- Container status ---"
declare -A SVCS=(
  [bitrix_redis]="Redis 8.x"
  [bitrix_mysql]="Percona MySQL 8.0"
  [bitrix_opensearch]="OpenSearch 2.x"
  [bitrix_php]="PHP 8.2-FPM"
  [bitrix_cron]="PHP cron"
  [bitrix_nginx]="nginx 1.30"
  [bitrix_push_sub]="push-server sub"
  [bitrix_push_pub]="push-server pub"
  [bitrix_postfix]="Postfix SMTP relay"
  [bitrix_ssl]="SSL manager"
)
for name in "${!SVCS[@]}"; do
  STATUS=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
  RESTARTS=$(docker inspect --format '{{.RestartCount}}' "$name" 2>/dev/null || echo "?")
  if [[ "$STATUS" == "running" ]]; then
    ok "  ${SVCS[$name]} ($name): running [restarts: $RESTARTS]"
  else
    warn "  ${SVCS[$name]} ($name): $STATUS"
    docker logs "$name" --tail 5 2>/dev/null | sed 's/^/    /'
    FAILED=$((FAILED+1))
  fi
done

# ── MySQL ─────────────────────────────────────────────────────────────────
echo
ok "--- MySQL (Percona 8.0) ---"
MYSQL_PASS=$(grep MYSQL_ROOT_PASSWORD "${PROJECT_DIR}/.env_sql" | cut -d= -f2 | tr -d '"' | tr -d "'")
if docker exec bitrix_mysql mysql -uroot "-p${MYSQL_PASS}" -e "SELECT 1" >/dev/null 2>&1; then
  Q="SELECT variable_name, variable_value FROM performance_schema.global_variables WHERE variable_name IN ('innodb_buffer_pool_size','max_connections','tmpdir','slow_query_log','innodb_io_capacity') ORDER BY 1"
  docker exec bitrix_mysql mysql -uroot "-p${MYSQL_PASS}" -t -e "$Q" 2>/dev/null | grep -v "Warning"
  ok "  MySQL responding"
else
  warn "  MySQL not responding -- docker logs bitrix_mysql"
  FAILED=$((FAILED+1))
fi

# ── Redis ─────────────────────────────────────────────────────────────────
echo
ok "--- Redis ---"
PONG=$(docker exec bitrix_redis redis-cli PING 2>/dev/null || echo "FAIL")
MAXMEM_BYTES=$(docker exec bitrix_redis redis-cli CONFIG GET maxmemory 2>/dev/null | tail -1 || echo "0")
MAXMEM_GB=$(( ${MAXMEM_BYTES:-0} / 1073741824 ))
POLICY=$(docker exec bitrix_redis redis-cli CONFIG GET maxmemory-policy 2>/dev/null | tail -1 || echo "?")
[[ "$PONG" == "PONG" ]] && ok "  Redis: PONG | maxmemory=${MAXMEM_GB}G | policy=$POLICY" \
  || { warn "  Redis not responding"; FAILED=$((FAILED+1)); }

# ── PHP sessions ──────────────────────────────────────────────────────────
echo
ok "--- PHP sessions ---"
SESS_H=$(docker exec bitrix_php php -r "echo ini_get('session.save_handler');" 2>/dev/null || echo "?")
SESS_P=$(docker exec bitrix_php php -r "echo ini_get('session.save_path');"    2>/dev/null || echo "?")
WORKERS=$(docker exec bitrix_php php-fpm -t 2>&1 | grep "pm.max_children" | awk '{print $NF}' || echo "?")
[[ "$SESS_H" == "redis" ]] \
  && ok "  PHP session: handler=$SESS_H path=$SESS_P" \
  || warn "  PHP session handler=$SESS_H (expected: redis)"
ok "  PHP-FPM pm.max_children=$(docker exec bitrix_php grep -o 'pm.max_children = [0-9]*' /usr/local/etc/php-fpm.d/www.conf 2>/dev/null | awk '{print $3}')"

# ── OpenSearch ────────────────────────────────────────────────────────────
echo
ok "--- OpenSearch 2.x ---"
OS_HEALTH=$(docker exec bitrix_php wget -qO- "http://opensearch:9200/_cluster/health" 2>/dev/null || echo "")
if echo "$OS_HEALTH" | grep -q '"status"'; then
  OS_ST=$(echo "$OS_HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','?'))" 2>/dev/null)
  ok "  OpenSearch cluster health: $OS_ST"
else
  warn "  OpenSearch not responding yet (normal on first start -- wait 1-2 min, then check: docker logs bitrix_opensearch)"
fi

# ── Postfix ───────────────────────────────────────────────────────────────
echo
ok "--- Postfix SMTP relay ---"
PF=$(docker exec bitrix_postfix postfix status 2>&1 | head -1 || echo "?")
ok "  $PF"
ok "  Route: PHP mail() -> msmtp -> postfix:25 -> smtp.mail.ru:587"

# ── nginx / HTTP ──────────────────────────────────────────────────────────
echo
ok "--- nginx / HTTP ---"
HTTP_CODE=$(curl -skI "https://${DOMAIN}/" --max-time 10 | head -1 | awk '{print $2}' || echo "?")
[[ "$HTTP_CODE" =~ ^(200|301|302)$ ]] \
  && ok "  https://${DOMAIN}/ -> HTTP $HTTP_CODE" \
  || { warn "  https://${DOMAIN}/ -> HTTP $HTTP_CODE"; ok "  On first install: run wizard at https://${DOMAIN}/bitrix/wizard/"; }

# ── fail2ban ─────────────────────────────────────────────────────────────
echo
ok "--- fail2ban ---"
F2B=$(fail2ban-client ping 2>/dev/null | grep -c "pong" || echo 0)
[[ "$F2B" -gt 0 ]] \
  && ok "  Active jails: $(fail2ban-client status 2>/dev/null | grep 'Jail list' | sed 's/.*://')" \
  || warn "  fail2ban not responding"

# ── Summary ───────────────────────────────────────────────────────────────
echo
if [[ $FAILED -eq 0 ]]; then
  echo -e "${GREEN}+----------------------------------------------------------+${NC}"
  echo -e "${GREEN}|  Deploy complete -- all checks passed!                   |${NC}"
  echo -e "${GREEN}+----------------------------------------------------------+${NC}"
else
  echo -e "${YELLOW}+----------------------------------------------------------+${NC}"
  echo -e "${YELLOW}|  Deploy done with $FAILED warning(s)                     |${NC}"
  echo -e "${YELLOW}|  Check: docker logs <container_name> --tail 50           |${NC}"
  echo -e "${YELLOW}+----------------------------------------------------------+${NC}"
fi

echo
echo "Quick reference:"
echo "  docker compose ps                                -- all containers"
echo "  docker compose logs -f --tail 50 mysql          -- MySQL log stream"
echo "  docker compose logs -f --tail 50 postfix        -- mail log stream"
echo "  docker compose restart nginx                    -- reload nginx (after PHP restart)"
echo "  fail2ban-client status nginx-probe              -- banned IPs"
echo "  docker exec bitrix_redis redis-cli -n 1 DBSIZE  -- PHP session count"
echo "  ls -la ${PROJECT_DIR}/volumes/                  -- LVM symlinks"
echo
echo "First-time Bitrix install:"
echo "  Open: https://${DOMAIN}/bitrix/wizard/"
echo
echo "Set FTP password:  passwd ${FTP_USER}"