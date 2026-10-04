<?php
/**
 * IDDigital Hosting v2.14.0 — painel web (MiniPainel)
 * O painel não executa comandos: lê o estado (state.json) e coloca tarefas
 * numa fila, processadas como root pelo worker (mpanel worker).
 * As tarefas são assíncronas: o painel acompanha-as sem ficar bloqueado,
 * o que permite reiniciar serviços (incluindo o PHP do próprio painel).
 */
declare(strict_types=1);

const MP_VERSION = '2.14.0';
const MP_DATA    = '/var/lib/minipainel';
const MP_QUEUE   = MP_DATA . '/queue';
const MP_RESULTS = MP_DATA . '/results';
const MP_TMP     = MP_DATA . '/tmp';
const MP_RL      = MP_DATA . '/ratelimit';
const MP_STATE   = MP_DATA . '/state.json';
const MP_AUTH    = MP_DATA . '/auth.json';
const MP_IDLE    = 7200;
const MP_STATS   = MP_DATA . '/stats';
const MP_BK      = '/var/backups/minipainel';
const RX_SITE    = '/^[a-z][a-z0-9-]{0,23}$/';
const RX_DB      = '/^[a-z][a-z0-9_]{0,31}$/';
const RX_PASS    = '/^[A-Za-z0-9._@%+=:,!#*-]{8,64}$/';
const RX_PHP     = '/^[5-8]\.[0-9]{1,2}$/';
const RX_EXT     = '/^[a-z0-9_]{2,20}$/';
const RX_SVC     = '/^(nginx|mariadb|php-[5-8]\.[0-9]{1,2})$/';

/* chave => [rótulo, mínimo, máximo, unidade, opção do CLI, diretiva] */
const LIMITS = [
    'memory'     => ['Memória', 32, 8192, 'MB', '--memory', 'memory_limit'],
    'upload'     => ['Upload máximo', 1, 8192, 'MB', '--upload', 'upload_max_filesize e post_max_size'],
    'exec'       => ['Tempo de execução', 5, 3600, 's', '--exec', 'max_execution_time'],
    'input_time' => ['Tempo de receção de dados', 5, 3600, 's', '--input-time', 'max_input_time'],
    'input_vars' => ['Máximo de variáveis', 100, 100000, '', '--input-vars', 'max_input_vars'],
];
const LIMIT_DEFAULTS = ['memory' => 256, 'upload' => 128, 'exec' => 120, 'input_time' => 120, 'input_vars' => 5000];

/* Pedido interno do nginx (auth_request) para proteger o phpMyAdmin.
   Não bloqueia a sessão, para não atrasar os pedidos paralelos do phpMyAdmin. */
if ((string)($_SERVER['MP_AUTH_CHECK'] ?? '') === '1') {
    $authOk = false;
    session_name('MPSESS');
    if (isset($_COOKIE['MPSESS']) && is_string($_COOKIE['MPSESS']) && preg_match('/^[A-Za-z0-9,-]{20,128}$/', $_COOKIE['MPSESS'])) {
        session_start(['read_and_close' => true]);
        $seen = (int)($_SESSION['seen'] ?? 0);
        $authOk = !empty($_SESSION['user']) && time() - $seen <= MP_IDLE;
        if ($authOk && time() - $seen > 60) { session_start(); $_SESSION['seen'] = time(); session_write_close(); }
    }
    http_response_code($authOk ? 204 : 401);
    exit;
}

header('X-Frame-Options: DENY');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: same-origin');
header('Cache-Control: no-store');
header("Content-Security-Policy: default-src 'self'; style-src 'unsafe-inline'; script-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");

session_name('MPSESS');
session_start();

/* ---------- utilitários ---------- */
function h($v): string { return htmlspecialchars((string)$v, ENT_QUOTES, 'UTF-8'); }
function post(string $k): string { $v = $_POST[$k] ?? ''; return is_string($v) ? trim($v) : ''; }
function post_raw(string $k): string { $v = $_POST[$k] ?? ''; return is_string($v) ? $v : ''; }
function qget(string $k): string { $v = $_GET[$k] ?? ''; return is_string($v) ? $v : ''; }
function jload(string $f): ?array {
    $d = @file_get_contents($f);
    if ($d === false) return null;
    $j = json_decode($d, true);
    return is_array($j) ? $j : null;
}
function csrf(): string {
    if (empty($_SESSION['csrf'])) $_SESSION['csrf'] = bin2hex(random_bytes(32));
    return $_SESSION['csrf'];
}
function csrf_ok(): bool {
    $t = $_POST['csrf'] ?? '';
    return is_string($t) && $t !== '' && hash_equals((string)($_SESSION['csrf'] ?? ''), $t);
}
function csrf_field(): string { return '<input type="hidden" name="csrf" value="' . h(csrf()) . '">'; }
function act_fields(string $a, array $extra = []): string {
    $o = csrf_field() . '<input type="hidden" name="a" value="' . h($a) . '">';
    foreach ($extra as $k => $v) $o .= '<input type="hidden" name="' . h($k) . '" value="' . h($v) . '">';
    return $o;
}
function flash(bool $ok, string $m, bool $sticky = false): void { $_SESSION['flash'][] = [$ok, $m, $sticky || !$ok]; }
function go(string $p, array $q = []): void {
    $ref = (string)($_SERVER['HTTP_REFERER'] ?? '');
    if (!isset($q['t']) && preg_match('/[?&]p=' . preg_quote($p, '/') . '(&|$)/', $ref) && preg_match('/[?&]t=([a-z]{2,20})(&|$)/', $ref, $mm)) $q['t'] = $mm[1];
    header('Location: ?' . http_build_query(['p' => $p] + $q));
    exit;
}
/* ---------- auditoria e verificação em dois passos ---------- */
function audit(string $action, bool $ok = true, ?string $user = null): void {
    $line = json_encode(['ts' => time(), 'ip' => (string)($_SERVER['REMOTE_ADDR'] ?? ''), 'user' => substr((string)($user ?? ($_SESSION['user'] ?? '')), 0, 40), 'action' => substr($action, 0, 300), 'ok' => $ok], JSON_UNESCAPED_UNICODE);
    @file_put_contents(MP_DATA . '/logs/audit.log', $line . "\n", FILE_APPEND | LOCK_EX);
    if (function_exists('openlog')) { @openlog('minipainel-audit', LOG_PID, LOG_AUTHPRIV); @syslog($ok ? LOG_NOTICE : LOG_WARNING, $line); @closelog(); }
}
function b32_encode(string $b): string {
    $a = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; $bits = ''; $o = '';
    foreach (str_split($b) as $c) $bits .= str_pad(decbin(ord($c)), 8, '0', STR_PAD_LEFT);
    foreach (str_split($bits, 5) as $ch) $o .= $a[bindec(str_pad($ch, 5, '0'))];
    return $o;
}
function b32_decode(string $s): string {
    $a = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; $bits = ''; $o = '';
    foreach (str_split(strtoupper(preg_replace('/[^A-Za-z2-7]/', '', $s) ?? '')) as $c) $bits .= str_pad(decbin((int)strpos($a, $c)), 5, '0', STR_PAD_LEFT);
    foreach (str_split($bits, 8) as $by) if (strlen($by) === 8) $o .= chr(bindec($by));
    return $o;
}
function totp_code(string $secret, int $step): string {
    $h = hash_hmac('sha1', pack('N2', 0, $step), b32_decode($secret), true);
    $p = ord($h[19]) & 0x0f;
    $v = ((ord($h[$p]) & 0x7f) << 24) | (ord($h[$p + 1]) << 16) | (ord($h[$p + 2]) << 8) | ord($h[$p + 3]);
    return str_pad((string)($v % 1000000), 6, '0', STR_PAD_LEFT);
}
function totp_verify(string $secret, string $code): ?int {
    $code = preg_replace('/\D/', '', $code) ?? '';
    if (strlen($code) !== 6 || $secret === '') return null;
    $now = intdiv(time(), 30);
    for ($d = -1; $d <= 1; $d++) { if (hash_equals(totp_code($secret, $now + $d), $code)) return $now + $d; }
    return null;
}
function totp_ok(array $auth, string $code): bool { // código de 6 dígitos, sem reutilização
    $st = totp_verify((string)($auth['totp'] ?? ''), $code);
    if ($st === null) return false;
    $f = MP_RL . '/totp-last.json';
    $last = (int)((jload($f) ?? [])['step'] ?? 0);
    if ($st <= $last) return false;
    @file_put_contents($f, (string)json_encode(['step' => $st]), LOCK_EX);
    return true;
}
function recovery_use(array $auth, string $code): bool {
    $c = strtolower(preg_replace('/[^0-9a-fA-F]/', '', $code) ?? '');
    if (strlen($c) !== 12) return false;
    $h = hash('sha256', substr($c, 0, 6) . '-' . substr($c, 6));
    $list = is_array($auth['recovery'] ?? null) ? $auth['recovery'] : [];
    if (!in_array($h, $list, true)) return false;
    $uf = MP_DATA . '/logs/2fa-used.json';
    $used = jload($uf) ?? [];
    if (in_array($h, $used, true)) return false;
    $used[] = $h;
    @file_put_contents($uf, (string)json_encode($used), LOCK_EX);
    return true;
}
function reauth_ok(?array $auth): bool { // password atual e, com 2FA ativo, também o código
    if ($auth === null || !password_verify(post_raw('atual'), (string)($auth['hash'] ?? ''))) return false;
    if (!empty($auth['totp']) && !totp_ok($auth, post('code')) && !recovery_use($auth, post('code'))) return false;
    return true;
}
function reauth_fields(?array $auth): string {
    $h = '<label class="fld">Password do painel<input class="in" type="password" name="atual" required autocomplete="current-password"></label>';
    if (!empty($auth['totp'])) $h .= '<label class="fld">Código de verificação<input class="in mono" name="code" required inputmode="numeric" autocomplete="one-time-code" maxlength="14"></label>';
    return $h;
}
function ip_in(string $ip, string $net): bool {
    $p = explode('/', $net, 2);
    $a = @inet_pton($ip); $b = @inet_pton($p[0]);
    if ($a === false || $b === false || strlen($a) !== strlen($b)) return false;
    $bits = isset($p[1]) ? (int)$p[1] : strlen($a) * 8;
    $by = intdiv($bits, 8); $r = $bits % 8;
    if (substr($a, 0, $by) !== substr($b, 0, $by)) return false;
    if ($r === 0) return true;
    $m = (0xFF << (8 - $r)) & 0xFF;
    return (ord($a[$by]) & $m) === (ord($b[$by]) & $m);
}
/* ---------- logs dos sites (nginx: lidos diretamente; PHP e cron: pelo gestor de ficheiros do site) ---------- */
const MP_SITE_LOGS = '/var/log/minipainel/sites';
const MP_TERM_LOG  = '/var/log/minipainel/terminal';
function log_tail(string $f, int $max, string $grep = '', int $maxBytes = 33554432): array {
    if (!is_file($f) || is_link($f)) return [];
    $fh = @fopen($f, 'r'); if (!$fh) return [];
    $size = (int)filesize($f); $pos = $size; $buf = ''; $out = [];
    while ($pos > 0 && count($out) < $max && $size - $pos < $maxBytes) {
        $rd = min(65536, $pos); $pos -= $rd; fseek($fh, $pos); $buf = (string)fread($fh, $rd) . $buf;
        $parts = explode("\n", $buf); $buf = $pos > 0 ? (string)array_shift($parts) : '';
        $sel = [];
        foreach ($parts as $ln) { if ($ln === '') continue; if ($grep !== '' && stripos($ln, $grep) === false) continue; $sel[] = $ln; }
        $out = array_merge($sel, $out);
    }
    if ($buf !== '' && ($grep === '' || stripos($buf, $grep) !== false)) array_unshift($out, $buf);
    fclose($fh);
    return array_slice($out, -$max);
}
function log_parse(string $ln): ?array { // formato "combined" do nginx
    if (!preg_match('/^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+)[^"]*" (\d{3}) (\d+|-) "([^"]*)" "([^"]*)"/', $ln, $m)) return null;
    $t = DateTime::createFromFormat('d/M/Y:H:i:s O', $m[2]);
    $rt = null; $cs = '';
    if (preg_match('/ rt=([0-9.]+)(?: urt=\S+)?(?: cs=(\S+))?\s*$/', $ln, $x)) { $rt = (float)$x[1]; $cs = ($x[2] ?? '') === '-' ? '' : (string)($x[2] ?? ''); }
    return ['ip' => $m[1], 't' => $t ? $t->getTimestamp() : 0, 'm' => $m[3], 'u' => $m[4], 's' => (int)$m[5], 'b' => $m[6] === '-' ? 0 : (int)$m[6], 'r' => $m[7], 'a' => $m[8], 'rt' => $rt, 'cs' => $cs];
}
function log_is_bot(string $ua): bool { return (bool)preg_match('/bot|crawl|spider|slurp|bingpreview|facebookexternalhit|curl|wget|python|go-http|semrush|ahrefs|mj12|petal|yandex|dotbot|scrapy/i', $ua); }
function log_summary(string $f): array { // últimas 24 h
    $since = time() - 86400; $sum = ['total' => 0, 'c' => ['2' => 0, '3' => 0, '4' => 0, '5' => 0], 'bots' => 0, 'bytes' => 0, 'ips' => [], 'e404' => [], 'e5xx' => [], 'slow' => [], 'cache' => [], 'rtn' => 0, 'rts' => 0.0];
    foreach (log_tail($f, 300000, '', 67108864) as $ln) {
        $p = log_parse($ln); if (!$p || $p['t'] < $since) continue;
        $sum['total']++; $k = (string)intdiv($p['s'], 100); if (isset($sum['c'][$k])) $sum['c'][$k]++;
        $sum['bytes'] += $p['b']; if (log_is_bot($p['a'])) $sum['bots']++;
        $sum['ips'][$p['ip']] = ($sum['ips'][$p['ip']] ?? 0) + 1;
        $u = strtok($p['u'], '?') ?: $p['u'];
        if ($p['s'] === 404) $sum['e404'][$u] = ($sum['e404'][$u] ?? 0) + 1;
        if ($p['s'] >= 500) $sum['e5xx'][$u] = ($sum['e5xx'][$u] ?? 0) + 1;
        if ($p['rt'] !== null && !preg_match('/\.(css|js|png|jpe?g|gif|webp|svg|ico|woff2?|ttf|map)$/i', $u)) {
            $sum['rtn']++; $sum['rts'] += $p['rt'];
            $q0 = $sum['slow'][$u] ?? [0, 0.0, 0.0]; $sum['slow'][$u] = [$q0[0] + 1, $q0[1] + $p['rt'], max($q0[2], $p['rt'])];
        }
        if ($p['cs'] !== '') $sum['cache'][$p['cs']] = ($sum['cache'][$p['cs']] ?? 0) + 1;
    }
    $sum['slow'] = array_filter($sum['slow'], function ($v) { return $v[0] >= 2; });
    uasort($sum['slow'], function ($a, $b) { return ($b[1] / $b[0]) <=> ($a[1] / $a[0]); });
    $sum['slow'] = array_slice($sum['slow'], 0, 10, true);
    foreach (['ips', 'e404', 'e5xx'] as $k) { arsort($sum[$k]); $sum[$k] = array_slice($sum[$k], 0, 10, true); }
    return $sum;
}
/* ---------- países (base DB-IP Lite, consultada localmente) e paginação ---------- */
const MP_GEO = '/var/lib/minipainel/geoip';
function geo_cc(string $ip): string {
    static $fh = [], $n = [], $cache = [];
    if (isset($cache[$ip])) return $cache[$ip];
    $v6 = strpos($ip, ':') !== false; $k = $v6 ? 6 : 4; $rec = $v6 ? 34 : 10; $cc = '';
    if (!isset($fh[$k])) { $f = MP_GEO . '/v' . $k . '.bin'; $fh[$k] = is_readable($f) ? fopen($f, 'rb') : false; $n[$k] = $fh[$k] ? intdiv((int)filesize($f), $rec) : 0; }
    if ($fh[$k]) {
        if ($v6) { $x = @inet_pton($ip); if ($x === false || strlen($x) !== 16) return $cache[$ip] = ''; }
        else { $x = ip2long($ip); if ($x === false) return $cache[$ip] = ''; }
        $lo = 0; $hi = $n[$k] - 1;
        while ($lo <= $hi) {
            $mid = ($lo + $hi) >> 1; fseek($fh[$k], $mid * $rec); $r = (string)fread($fh[$k], $rec);
            if ($v6) { $a = substr($r, 0, 16); $b = substr($r, 16, 16); $lt = strcmp($x, $a) < 0; $gt = strcmp($x, $b) > 0; }
            else { $u = unpack('Na/Nb', $r); $lt = $x < $u['a']; $gt = $x > $u['b']; }
            if ($lt) $hi = $mid - 1; elseif ($gt) $lo = $mid + 1; else { $cc = substr($r, $rec - 2, 2); break; }
        }
    }
    return $cache[$ip] = $cc;
}
function cc_name(string $cc): string {
    if (!preg_match('/^[A-Z]{2}$/', $cc)) return 'Rede local ou desconhecido';
    if (class_exists('Locale')) { $n = Locale::getDisplayRegion('-' . $cc, 'pt_PT'); if ($n !== '' && $n !== $cc) return $n; }
    return $cc;
}
function cc_flag(string $cc): string { return preg_match('/^[A-Z]{2}$/', $cc) ? mb_chr(127397 + ord($cc[0])) . mb_chr(127397 + ord($cc[1])) : '🌐'; }
function paginate(array $items, int $per = 50, string $param = 'pg'): array {
    $total = count($items); $pages = max(1, (int)ceil($total / $per)); $pg = min($pages, max(1, (int)qget($param)));
    return [array_slice($items, ($pg - 1) * $per, $per), $pg, $pages, $total];
}
function pager(int $pg, int $pages, int $total, string $param = 'pg', string $what = 'itens'): string {
    if ($pages <= 1) return '';
    $q = $_GET; $link = function (int $p) use ($q, $param) { $q[$param] = $p; return '?' . h(http_build_query($q)); };
    $h = '<nav class="pager" aria-label="Páginas"><span class="mu">' . $total . ' ' . h($what) . '</span>';
    $h .= $pg > 1 ? '<a class="chip sm" href="' . $link($pg - 1) . '">‹ Anterior</a>' : '';
    foreach (array_unique([1, max(1, $pg - 2), $pg - 1, $pg, $pg + 1, min($pages, $pg + 2), $pages]) as $p) {
        if ($p < 1 || $p > $pages) continue;
        $h .= '<a class="chip sm' . ($p === $pg ? ' prim' : '') . '" href="' . $link($p) . '">' . $p . '</a>';
    }
    $h .= $pg < $pages ? '<a class="chip sm" href="' . $link($pg + 1) . '">Seguinte ›</a>' : '';
    return $h . '</nav>';
}
/* ---------- processos: origem de cada um ---------- */
function proc_origin(string $user, string $args): array { // [tipo, rótulo, site]
    if (preg_match('/^mp_([a-z][a-z0-9-]{0,23})$/', $user, $m)) return ['site', 'Site ' . $m[1], $m[1]];
    if (preg_match('/php-fpm: pool mp-fm-/', $args)) return ['painel', 'Painel (ficheiros)', ''];
    if (preg_match('/php-fpm: pool mp-([a-z][a-z0-9-]{0,23})\b/', $args, $m)) return ['site', 'Site ' . $m[1], $m[1]];
    if (preg_match('/^\[.*\]$/', $args)) return ['sistema', 'Kernel', ''];
    if (strpos($args, 'php-fpm: master') === 0) return ['web', 'PHP (FPM)', ''];
    if (in_array($user, ['vmail', 'dovecot', 'dovenull', 'postfix', '_rspamd', 'rspamd', 'redis', 'clamav', 'unbound', 'opendkim'], true)
        || preg_match('#^(/usr/lib/postfix/|/usr/libexec/postfix/|/usr/sbin/(dovecot|rspamd|clamd|freshclam|unbound|postfix)|dovecot/|rspamd:|redis-server|/usr/bin/redis)#', $args)) return ['email', 'Email', ''];
    if ($user === 'mysql' || preg_match('#(^|/)(mariadbd|mysqld)\b#', $args)) return ['bd', 'Base de dados', ''];
    if (in_array($user, ['www-data', 'nginx'], true) || strpos($args, 'nginx:') === 0) return ['web', 'Servidor web', ''];
    if (in_array($user, ['minipainel', 'minipainel-pma', 'mp-webmail'], true) || preg_match('#mpanel|minipainel|ttyd#', $args)) return ['painel', 'Painel', ''];
    if ($user === 'nsd' || preg_match('#(^|/)nsd\b#', $args)) return ['sistema', 'DNS', ''];
    if (preg_match('#pure-ftpd#', $args)) return ['sistema', 'FTP', ''];
    return ['sistema', 'Sistema operativo', ''];
}
function proc_protected_php(int $pid, string $comm, string $args, string $user): bool { // só para a interface; o servidor volta a verificar
    if ($pid <= 2 || preg_match('/^\[.*\]$/', $args)) return true;
    if (preg_match('/^(systemd|systemd-.*|init|dbus-daemon|dbus-broker|agetty|cron|crond|rsyslogd|journald|udevd|polkitd|mariadbd|mysqld|master|containerd|dockerd)$/', $comm)) return true;
    if (preg_match('#^(nginx: master|php-fpm: master|php-fpm: pool minipainel|sshd: /usr/sbin/sshd|/usr/sbin/sshd|/usr/sbin/dovecot|/usr/sbin/nsd|nsd -c)#', $args) || preg_match('#mpanel-stats|mpanel worker#', $args) || $args === 'dovecot') return true;
    return $user === 'minipainel' && strpos($args, 'php-fpm') === 0;
}
/* ---------- manual: leitor de Markdown (títulos, parágrafos, listas, tabelas, código, negrito, ligações) ---------- */
const MP_MANUAL = '/opt/minipainel/manual.md';
function md_inline(string $t): string {
    $out = '';
    foreach (preg_split('/(`[^`]+`)/', $t, -1, PREG_SPLIT_DELIM_CAPTURE) ?: [] as $p) {
        if (strlen($p) > 1 && $p[0] === '`' && substr($p, -1) === '`') { $out .= '<code>' . h(substr($p, 1, -1)) . '</code>'; continue; }
        $x = h($p);
        $x = preg_replace('/\*\*(.+?)\*\*/', '<b>$1</b>', $x) ?? $x;
        $x = preg_replace('/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/', '<a href="$2" target="_blank" rel="noopener">$1</a>', $x) ?? $x;
        $out .= $x;
    }
    return $out;
}
function md_cells(string $row): array { // separa as células de uma linha de tabela (\| é uma barra dentro da célula)
    $row = trim($row); $row = preg_replace('/^\||\|$/', '', $row) ?? $row;
    return array_map(function ($c) { return trim(str_replace("\x01", '|', $c)); }, explode('|', str_replace('\|', "\x01", $row)));
}
function md_render(string $md, array &$toc): string {
    $L = preg_split('/\r?\n/', $md) ?: []; $n = count($L); $h = ''; $i = 0; $open = false; $sec = 0;
    while ($i < $n) {
        $ln = $L[$i];
        if (preg_match('/^```/', $ln)) { // bloco de código
            $buf = []; $i++;
            while ($i < $n && !preg_match('/^```/', $L[$i])) $buf[] = $L[$i++];
            $i++; $h .= '<pre class="md-code"><code>' . h(implode("\n", $buf)) . '</code></pre>'; continue;
        }
        if (preg_match('/^(#{1,3})\s+(.*)$/', $ln, $m)) { // títulos
            $lv = strlen($m[1]); $txt = $m[2];
            if ($lv === 1) { $h .= '<h1 class="md-h1">' . md_inline($txt) . '</h1>'; $i++; continue; }
            if ($lv === 2) { if ($open) $h .= '</section>'; $sec++; $id = 's' . $sec; $toc[] = ['id' => $id, 't' => $txt, 'sub' => []]; $h .= '<section class="md-sec" id="' . $id . '"><h2>' . md_inline($txt) . '</h2>'; $open = true; }
            else { $id = 's' . $sec . '-' . (count($toc[count($toc) - 1]['sub'] ?? []) + 1); if ($toc) $toc[count($toc) - 1]['sub'][] = ['id' => $id, 't' => $txt]; $h .= '<h3 id="' . $id . '">' . md_inline($txt) . '</h3>'; }
            $i++; continue;
        }
        if (preg_match('/^\|/', $ln) && $i + 1 < $n && preg_match('/^\|\s*-{3,}/', $L[$i + 1])) { // tabela
            $hd = md_cells($ln); $i += 2; $rows = [];
            while ($i < $n && preg_match('/^\|/', $L[$i])) $rows[] = md_cells($L[$i++]);
            $h .= '<div class="md-tw"><table class="md-t"><thead><tr>' . implode('', array_map(function ($c) { return '<th>' . md_inline($c) . '</th>'; }, $hd)) . '</tr></thead><tbody>';
            foreach ($rows as $r) $h .= '<tr>' . implode('', array_map(function ($c) { return '<td>' . md_inline($c) . '</td>'; }, $r)) . '</tr>';
            $h .= '</tbody></table></div>'; continue;
        }
        if (preg_match('/^(\s*)([-*]|\d+\.)\s+/', $ln)) { // listas (com um nível de subitens)
            $ord = (bool)preg_match('/^\s*\d+\./', $ln); $h .= $ord ? '<ol class="md-l">' : '<ul class="md-l">'; $inSub = false;
            while ($i < $n && preg_match('/^(\s*)([-*]|\d+\.)\s+(.*)$/', $L[$i], $m)) {
                $txt = $m[3]; $chk = '';
                if (preg_match('/^\[( |x)\]\s+(.*)$/i', $txt, $c)) { $chk = '<input type="checkbox" disabled' . (strtolower($c[1]) === 'x' ? ' checked' : '') . '> '; $txt = $c[2]; }
                if (strlen($m[1]) >= 2) { if (!$inSub) { $h = preg_replace('/<\/li>$/', '', $h) ?? $h; $h .= '<ul class="md-l">'; $inSub = true; } $h .= '<li>' . $chk . md_inline($txt) . '</li>'; }
                else { if ($inSub) { $h .= '</ul></li>'; $inSub = false; } $h .= '<li>' . $chk . md_inline($txt) . '</li>'; }
                $i++;
            }
            if ($inSub) $h .= '</ul></li>';
            $h .= $ord ? '</ol>' : '</ul>'; continue;
        }
        if (trim($ln) === '') { $i++; continue; }
        $buf = [];
        while ($i < $n && trim($L[$i]) !== '' && !preg_match('/^(#{1,3}\s|```|\||\s*([-*]|\d+\.)\s)/', $L[$i])) $buf[] = $L[$i++];
        $h .= '<p>' . md_inline(implode(' ', $buf)) . '</p>';
    }
    if ($open) $h .= '</section>';
    return $h;
}
function dns_purpose(array $r): array { // [grupo, texto]
    $n = (string)$r['name']; $t = (string)$r['type']; $v = (string)$r['value'];
    if ($t === 'A' || $t === 'AAAA') {
        if ($n === '@') return ['Site', 'Site: endereço principal'];
        if ($n === 'www') return ['Site', 'Site: endereço com www'];
        if (preg_match('/^ns\d*(\.|$)/', $n)) return ['Outros', 'Nameserver (este servidor DNS)'];
        if (preg_match('/^(mail|smtp|imap|webmail)(\.|$)/', $n)) return ['Email', 'Email: endereço do servidor de email'];
        return ['Site', 'Subdomínio (site ou serviço)'];
    }
    if ($t === 'CNAME') return ['Site', 'Atalho para ' . rtrim($v, '.')];
    if ($t === 'MX') return ['Email', 'Email: servidor que recebe o email'];
    if ($t === 'TXT') {
        if (stripos($v, 'v=spf1') !== false) return ['Email', 'Email: quem pode enviar (SPF)'];
        if (strpos($n, '_domainkey') !== false) return ['Email', 'Email: assinatura (DKIM)'];
        if (strpos($n, '_dmarc') === 0) return ['Email', 'Email: o que fazer a email falso (DMARC)'];
        return ['Outros', 'Texto (ex.: verificação Google/Microsoft)'];
    }
    if ($t === 'CAA') return ['Certificados', 'Certificados: quem os pode emitir'];
    if ($t === 'SRV') return ['Outros', 'Serviço (VoIP, Teams…)'];
    if ($t === 'NS') return ['Outros', 'Subdomínio gerido noutro servidor DNS'];
    return ['Outros', $t];
}
function dns_serial_date(string $s): string { return preg_match('/^(\d{4})(\d{2})(\d{2})\d{2}$/', $s, $m) ? $m[3] . '/' . $m[2] . '/' . $m[1] : $s; }
function valid_net(string $s): bool {
    $ip = $s; $bits = null;
    if (strpos($s, '/') !== false) { [$ip, $bits] = explode('/', $s, 2); if (!ctype_digit($bits)) return false; }
    if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) return $bits === null || ((int)$bits >= 8 && (int)$bits <= 32);
    if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) return $bits === null || ((int)$bits >= 32 && (int)$bits <= 128);
    return false;
}
/* Descrição em português de uma expressão cron (casos comuns; o resto fica "personalizada") */
function cron_human(string $w): string {
    $w = trim(preg_replace('/\s+/', ' ', $w));
    $macros = ['@hourly' => 'De hora a hora', '@daily' => 'Todos os dias à meia-noite', '@weekly' => 'Aos domingos à meia-noite', '@monthly' => 'No dia 1 de cada mês à meia-noite', '@yearly' => 'Uma vez por ano (1 de janeiro)', '@annually' => 'Uma vez por ano (1 de janeiro)'];
    if (isset($macros[$w])) return $macros[$w];
    $p = explode(' ', $w);
    if (count($p) !== 5) return 'Expressão inválida';
    [$mi, $ho, $dm, $mo, $dw] = $p;
    $days = ['domingo', 'segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado', 'domingo'];
    $hm = function ($h, $m) { return sprintf('%02d:%02d', (int)$h, (int)$m); };
    $n = '/^\d+$/';
    if ($dm === '*' && $mo === '*' && $dw === '*') {
        if ($mi === '*' && $ho === '*') return 'A cada minuto';
        if (preg_match('/^\*\/(\d+)$/', $mi, $m) && $ho === '*') return 'A cada ' . $m[1] . ' minutos';
        if (preg_match($n, $mi) && $ho === '*') return 'De hora a hora, ao minuto ' . (int)$mi;
        if (preg_match($n, $mi) && preg_match('/^\*\/(\d+)$/', $ho, $m)) return 'A cada ' . $m[1] . ' horas, ao minuto ' . (int)$mi;
        if (preg_match($n, $mi) && preg_match($n, $ho)) return 'Todos os dias às ' . $hm($ho, $mi);
    }
    if (preg_match($n, $mi) && preg_match($n, $ho) && $dm === '*' && $mo === '*') {
        if (preg_match('/^[0-7]$/', $dw)) return 'À ' . $days[(int)$dw] . ' às ' . $hm($ho, $mi);
        if ($dw === '1-5') return 'Dias úteis às ' . $hm($ho, $mi);
    }
    if (preg_match($n, $mi) && preg_match($n, $ho) && preg_match($n, $dm) && $mo === '*' && $dw === '*') return 'No dia ' . (int)$dm . ' de cada mês às ' . $hm($ho, $mi);
    return 'Expressão personalizada';
}
function ago(int $t, int $now): string {
    $d = $now - $t;
    if ($d < 60) return 'há instantes';
    if ($d < 3600) return 'há ' . intdiv($d, 60) . ' min';
    if ($d < 86400) return 'há ' . intdiv($d, 3600) . ' h';
    return 'há ' . intdiv($d, 86400) . ' d';
}
function fw_secs_php(string $d): int {
    if (!preg_match('/^(\d+)([smhd]?)$/', $d, $m)) return 0;
    return (int)$m[1] * ['' => 1, 's' => 1, 'm' => 60, 'h' => 3600, 'd' => 86400][$m[2]];
}
function valid_site(string $s): bool { return (bool)preg_match(RX_SITE, $s) && substr($s, -1) !== '-'; }
function site_limits(array $s): array {
    $l = is_array($s['limits'] ?? null) ? $s['limits'] : [];
    $o = [];
    foreach (LIMIT_DEFAULTS as $k => $d) $o[$k] = (int)($l[$k] ?? $d);
    $o['display_errors'] = !empty($l['display_errors']);
    return $o;
}
function host_only(): string {
    $h = (string)($_SERVER['HTTP_HOST'] ?? '');
    if ($h === '') $h = (string)($_SERVER['SERVER_ADDR'] ?? 'localhost');
    if ($h !== '' && $h[0] === '[') { $p = strpos($h, ']'); return $p === false ? $h : substr($h, 0, $p + 1); }
    return (string)preg_replace('/:\d+$/', '', $h);
}
function site_url(string $host, int $port): string { return 'http://' . $host . ($port === 80 ? '' : ':' . $port) . '/'; }
function fmt_uptime(int $s): string {
    if ($s >= 86400) { $d = intdiv($s, 86400); return $d . ($d === 1 ? ' dia' : ' dias'); }
    if ($s >= 3600) return intdiv($s, 3600) . ' h';
    return max(1, intdiv($s, 60)) . ' min';
}
function tone(string $name): string {
    $t = ['t-acc', 't-blue', 't-vio', 't-warn'];
    return $t[abs(crc32($name)) % 4];
}

/* ---------- ícones (SVG em linha, sem recursos externos) ---------- */
const ICONS = [
    'dash'   => '<rect x="4" y="4" width="6" height="8" rx="1.5"/><rect x="14" y="4" width="6" height="5" rx="1.5"/><rect x="4" y="16" width="6" height="4" rx="1.5"/><rect x="14" y="13" width="6" height="7" rx="1.5"/>',
    'world'  => '<circle cx="12" cy="12" r="9"/><path d="M3.6 9h16.8M3.6 15h16.8M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>',
    'db'     => '<ellipse cx="12" cy="6" rx="8" ry="3"/><path d="M4 6v6c0 1.7 3.6 3 8 3s8-1.3 8-3V6M4 12v6c0 1.7 3.6 3 8 3s8-1.3 8-3v-6"/>',
    'code'   => '<path d="M7 8l-4 4 4 4M17 8l4 4-4 4M14 4l-4 16"/>',
    'pulse'  => '<path d="M3 12h4l3 8 4-16 3 8h4"/>',
    'user'   => '<circle cx="12" cy="8" r="4"/><path d="M6 21v-2a4 4 0 0 1 4-4h4a4 4 0 0 1 4 4v2"/>',
    'plus'   => '<path d="M12 5v14M5 12h14"/>',
    'dots'   => '<circle cx="12" cy="5" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="12" cy="19" r="1"/>',
    'reload' => '<path d="M20 11A8 8 0 0 0 5.3 7.5M4 4v4h4M4 13a8 8 0 0 0 14.7 3.5M20 20v-4h-4"/>',
    'power'  => '<path d="M7 6a7.8 7.8 0 1 0 10 0M12 4v8"/>',
    'play'   => '<path d="M7 4v16l13-8z"/>',
    'stop'   => '<rect x="6" y="6" width="12" height="12" rx="2"/>',
    'moon'   => '<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9z"/>',
    'sun'    => '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    'out'    => '<path d="M14 8V6a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h7a2 2 0 0 0 2-2v-2M9 12h12M18 9l3 3-3 3"/>',
    'menu'   => '<path d="M4 6h16M4 12h16M4 18h16"/>',
    'x'      => '<path d="M18 6L6 18M6 6l12 12"/>',
    'ext'    => '<path d="M12 6H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-6M11 13l9-9M15 4h5v5"/>',
    'server' => '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/>',
    'cpu'    => '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M10 10h4v4h-4zM3 10h3M3 14h3M18 10h3M18 14h3M10 3v3M14 3v3M10 18v3M14 18v3"/>',
    'sliders'=> '<path d="M4 6h8M16 6h4M4 12h2M10 12h10M4 18h11M19 18h1"/><circle cx="14" cy="6" r="2"/><circle cx="8" cy="12" r="2"/><circle cx="17" cy="18" r="2"/>',
    'trash'  => '<path d="M4 7h16M10 11v6M14 11v6M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2l1-12M9 7V4h6v3"/>',
    'key'    => '<circle cx="8" cy="15" r="4"/><path d="M10.8 12.2L20 3M16 7l3 3M14 9l2 2"/>',
    'lock'   => '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
    'toggle' => '<rect x="2" y="7" width="20" height="10" rx="5"/><circle cx="8" cy="12" r="2.5"/>',
    'check'  => '<path d="M5 12l5 5L20 7"/>',
    'alert'  => '<circle cx="12" cy="12" r="9"/><path d="M12 8v5M12 16h.01"/>',
    'table'  => '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M3 15h18M9 10v10M15 10v10"/>',
    'shield' => '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/>',
    'folder' => '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    'folderplus' => '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><path d="M12 10.5v5M9.5 13h5"/>',
    'file'   => '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>',
    'zip'    => '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5M10 5h1M10 8h1M10 11h1M10 14h1v3h-1z"/>',
    'upload' => '<path d="M12 16V4M7 9l5-5 5 5M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2"/>',
    'download' => '<path d="M12 4v12M7 11l5 5 5-5M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2"/>',
    'home'   => '<path d="M4 11l8-7 8 7M6 9.5V20h12V9.5"/>',
    'edit'   => '<path d="M4 20h4L19 9l-4-4L4 16z"/><path d="M13.5 6.5l4 4"/>',
    'move'   => '<path d="M5 12h14M15 8l4 4-4 4M5 5v14"/>',
    'up'     => '<path d="M12 19V5M6 11l6-6 6 6"/>',
    'chev'   => '<path d="M6 9l6 6 6-6"/>',
    'ban'    => '<circle cx="12" cy="12" r="9"/><path d="M5.7 5.7l12.6 12.6"/>',
    'clock'  => '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    'shield' => '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/><path d="M9 12l2 2 4-4"/>',
    'book'   => '<path d="M4 4.5A2.5 2.5 0 0 1 6.5 2H20v17H6.5A2.5 2.5 0 0 0 4 21.5z"/><path d="M4 21.5A2.5 2.5 0 0 0 6.5 24H20v-5"/><path d="M8 7h8M8 11h6"/>',
    'bell'   => '<path d="M6 8a6 6 0 1 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>',
    'term'   => '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 9l3 3-3 3M12 15h5"/>',
    'logs'   => '<path d="M5 4h14v16H5z"/><path d="M8 8h8M8 12h8M8 16h5"/>',
    'dns'    => '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/><circle cx="12" cy="12" r="2"/>',
    'mail'   => '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 7l9 6 9-6"/>',
    'archive'=> '<rect x="3" y="4" width="18" height="5" rx="1.5"/><path d="M5 9v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9M10 13h4"/>',
];
/* Logótipo IDDigital Hosting (SVG em linha; o texto usa Arial ou equivalente métrico) */
function brand_logo(string $cls = 'brand-logo'): string {
    return '<svg class="' . h($cls) . '" viewBox="0 0 62.97 18.26" role="img" aria-label="IDDigital Hosting" xmlns="http://www.w3.org/2000/svg">'
        . '<path fill="#fff" d="M 10.696104,17.232981 C 9.5129773,16.842176 8.7260574,16.372185 7.9458244,15.590365 c -1.114,-1.116262 -1.7157692,-2.493883 -1.784426,-4.085056 -0.014374,-0.333159 -0.00865,-0.457078 0.029917,-0.647164 0.099813,-0.491997 0.3189197,-0.9047228 0.6668116,-1.2560559 0.8274806,-0.8356635 2.1314767,-1.0014038 3.189827,-0.405435 0.261545,0.1472777 0.723354,0.5928945 0.865202,0.8348679 0.214006,0.365059 0.316112,0.722462 0.350283,1.226095 0.0346,0.509923 0.209212,0.888772 0.54975,1.192761 0.343775,0.306876 0.717013,0.444297 1.196753,0.440625 0.525886,-0.004 0.905248,-0.154464 1.248715,-0.495181 0.235108,-0.233227 0.351055,-0.432298 0.431021,-0.740031 0.05275,-0.202983 0.05767,-0.273977 0.0419,-0.604108 C 14.662552,9.6065015 14.075119,8.3362136 12.999265,7.3056355 12.048684,6.3950566 10.862731,5.8387523 9.4907979,5.6598913 9.0218609,5.5987579 8.1134294,5.6186003 7.6756472,5.6995508 6.3679108,5.9413587 5.3155828,6.4713126 4.423572,7.3373012 3.910517,7.8353884 3.5632817,8.3130464 3.2715718,8.9219956 2.8556734,9.7901897 2.6909166,10.742689 2.7685575,11.830049 c 0.055923,0.783182 0.1672461,1.327816 0.436759,2.136766 0.1797827,0.539622 0.1806174,0.605202 0.00988,0.77594 -0.094738,0.09474 -0.119626,0.105283 -0.248473,0.105283 -0.1660019,0 -0.2799034,-0.05074 -0.3567817,-0.158919 C 2.5458511,14.598936 2.3598961,14.029801 2.2414377,13.561284 1.9117912,12.2575 1.8815863,10.789106 2.1618329,9.6914849 2.5560106,8.147645 3.6460195,6.7437251 5.1475424,5.8459267 7.3224606,4.545487 10.115883,4.5274669 12.319362,5.7996657 c 1.715935,0.9907074 2.873217,2.6135551 3.201846,4.4899243 0.07645,0.436502 0.110227,0.99086 0.07811,1.282039 -0.09176,0.832016 -0.604065,1.554468 -1.370112,1.932141 -0.425591,0.209822 -0.613626,0.24943 -1.177703,0.248064 -0.448773,-0.0011 -0.503433,-0.007 -0.732963,-0.07746 -0.87301,-0.268526 -1.522411,-0.925309 -1.734383,-1.754115 -0.02862,-0.111896 -0.06518,-0.356227 -0.08124,-0.542947 -0.03397,-0.394862 -0.102412,-0.627427 -0.25685,-0.872738 C 10.033828,10.167463 9.6093692,9.8704218 9.1869714,9.7634095 8.9528412,9.7040972 8.5620269,9.7097502 8.3021585,9.7762077 7.7275959,9.9231553 7.3086886,10.298932 7.111982,10.843844 c -0.074054,0.205143 -0.079853,0.249702 -0.077714,0.597194 0.00823,1.338483 0.5321468,2.601535 1.4809618,3.57036 0.7632773,0.779376 1.5081182,1.232518 2.5716382,1.564519 0.385877,0.120458 0.468886,0.189169 0.489653,0.405307 0.01075,0.111391 0.0027,0.152793 -0.03858,0.199197 -0.06269,0.07051 -0.307281,0.189422 -0.384621,0.187006 -0.03048,-9.44e-4 -0.236233,-0.06145 -0.457226,-0.134457 z M 6.6904661,17.164437 C 6.6024841,17.126114 6.1242485,16.631374 5.8040522,16.247429 5.3889771,15.749717 4.8134382,14.798822 4.5796876,14.224554 4.2080316,13.311486 4.0390981,12.44863 4.0344449,11.439633 4.0315488,10.812052 4.0523334,10.622866 4.1714275,10.192654 4.4032301,9.3552972 4.7979022,8.7065962 5.4566054,8.0802783 6.6288369,6.9656805 8.3477125,6.53442 9.9677565,6.9484445 11.395991,7.3134498 12.624593,8.385578 13.130529,9.7084047 c 0.179752,0.4699833 0.277045,0.9492623 0.284758,1.4027433 0.0039,0.2333 -0.0034,0.280082 -0.05759,0.367839 -0.07922,0.128173 -0.185,0.182331 -0.356132,0.182331 -0.271196,0 -0.421017,-0.180507 -0.42109,-0.50734 C 12.580366,10.630453 12.386096,9.9467474 12.106308,9.4850986 11.519961,8.5176305 10.503356,7.8549032 9.3382846,7.6806177 8.9765395,7.6265032 8.2377737,7.6433484 7.9250422,7.712841 6.3064884,8.0725247 5.1663437,9.216776 4.9019127,10.74686 c -0.048713,0.281867 -0.040483,1.037965 0.016134,1.482521 0.1392626,1.093469 0.435231,1.866856 1.1081841,2.895762 0.2908723,0.444728 0.4825181,0.683363 0.8959562,1.115635 0.2592815,0.271092 0.3388777,0.372163 0.3531957,0.448482 0.04265,0.227351 -0.069562,0.416401 -0.2855706,0.48112 -0.138344,0.04144 -0.193019,0.04037 -0.299346,-0.0059 z m 5.5207159,-1.54205 C 11.244805,15.510073 10.366448,15.094396 9.6752993,14.422292 8.8680425,13.637276 8.3961892,12.623707 8.3226635,11.516734 c -0.014569,-0.219391 -0.00898,-0.29249 0.029947,-0.394527 0.085794,-0.224661 0.3138299,-0.316951 0.5552824,-0.224741 0.1893172,0.0723 0.2336623,0.167004 0.2626962,0.561026 0.047867,0.649573 0.2164175,1.171521 0.5465019,1.692305 0.478925,0.755612 1.285532,1.346508 2.129856,1.56027 0.515341,0.130473 0.954321,0.158609 1.522371,0.09758 0.25322,-0.02721 0.502392,-0.04158 0.553715,-0.03196 0.0597,0.01126 0.129162,0.05719 0.192819,0.127645 0.08538,0.09451 0.0995,0.129217 0.0995,0.244514 0,0.157022 -0.07723,0.291864 -0.21238,0.370795 -0.171403,0.100097 -1.271672,0.163198 -1.791791,0.102753 z M 1.5515958,7.1526948 C 1.4873796,7.1293278 1.3569964,7.0003509 1.3135813,6.9172481 1.2251437,6.7479642 1.2653004,6.6170208 1.5014118,6.304768 2.2840541,5.2697396 3.2799235,4.4288405 4.4123052,3.8468473 5.3878281,3.345472 6.3437639,3.0512582 7.537093,2.8851119 c 0.4932469,-0.068671 1.9175775,-0.068671 2.4108249,0 2.4273701,0.3379607 4.3925631,1.4211281 5.8350501,3.2161431 0.273249,0.3400272 0.399842,0.5400029 0.399842,0.6316181 0,0.2252296 -0.195182,0.4254658 -0.414722,0.4254658 -0.07467,0 -0.158537,-0.019956 -0.201131,-0.047867 C 15.526779,7.0841417 15.377686,6.9100193 15.235648,6.7235286 14.506048,5.7655897 13.583182,5.007309 12.512436,4.485975 11.291939,3.8917299 10.097979,3.6209526 8.7009401,3.6215672 7.275676,3.6221957 6.0752471,3.8976143 4.8738546,4.4996332 3.7786794,5.0484254 2.900244,5.7808957 2.1395936,6.779554 2.0080624,6.952241 1.8662182,7.1112306 1.8243846,7.132865 1.7480846,7.172322 1.6292648,7.18096 1.5515958,7.1526948 Z M 3.8100123,2.7920664 C 3.497075,2.6920703 3.4166986,2.3074566 3.6618987,2.0833121 3.8117352,1.9463439 4.7695509,1.5215205 5.4243361,1.3016113 6.1572227,1.0554732 6.9907558,0.87692327 7.7864887,0.79561623 8.1981408,0.75355388 9.2857142,0.75413562 9.7123764,0.79666083 10.709221,0.89598665 11.56665,1.0988344 12.497294,1.4555195 12.959321,1.6326 13.75672,1.9956248 13.830686,2.0625642 13.908374,2.1328789 13.975124,2.3346744 13.95533,2.4394218 13.925446,2.5975653 13.842688,2.700374 13.702032,2.7540914 13.537356,2.8169826 13.504967,2.807915 12.926808,2.5369619 11.598059,1.9142622 10.445355,1.6422506 8.9975808,1.6097578 7.2861158,1.5713503 5.8249633,1.8966278 4.3478231,2.6448848 4.0272707,2.8072624 3.9358377,2.8322874 3.8100123,2.7920828 Z"/>'
        . '<g font-family="Arial,\'Liberation Sans\',Helvetica,sans-serif" font-weight="700">'
        . '<text x="18.0823" y="12.868" font-size="11.6841" fill="#16a596">id</text>'
        . '<text x="28.9553" y="12.7322" font-size="11.4367" fill="#fff">digital</text>'
        . '<text x="60.362" y="15.427" font-size="2.88254" font-weight="400" fill="#fff" text-anchor="end">hosting</text>'
        . '</g></svg>';
}

function ic(string $n, string $cls = ''): string {
    return '<svg class="i' . ($cls !== '' ? ' ' . $cls : '') . '" viewBox="0 0 24 24" aria-hidden="true">' . (ICONS[$n] ?? '') . '</svg>';
}

/* ---------- fila de tarefas (assíncrona) ---------- */
function job_submit(string $action, array $args, string $label): bool {
    $id = bin2hex(random_bytes(8));
    $payload = json_encode(['id' => $id, 'action' => $action, 'args' => array_values(array_map('strval', $args))]);
    $tmp = MP_TMP . '/' . $id . '.json';
    if (@file_put_contents($tmp, (string)$payload) === false || !@rename($tmp, MP_QUEUE . '/' . $id . '.json')) {
        @unlink($tmp);
        flash(false, 'Não foi possível colocar a tarefa na fila. Verifica as permissões de ' . MP_DATA . '.');
        return false;
    }
    $_SESSION['jobs'][$id] = ['label' => $label, 't' => time()];
    audit($label);
    return true;
}
function job_collect(): int {
    $jobs = is_array($_SESSION['jobs'] ?? null) ? $_SESSION['jobs'] : [];
    foreach ($jobs as $id => $j) {
        $id = (string)$id;
        if (!preg_match('/^[a-f0-9]{16}$/', $id)) { unset($jobs[$id]); continue; }
        $res = MP_RESULTS . '/' . $id . '.json';
        clearstatcache(true, $res);
        if (is_file($res)) {
            $r = jload($res);
            @unlink($res);
            unset($jobs[$id]);
            $ok  = (bool)($r['ok'] ?? false);
            $msg = trim((string)($r['msg'] ?? ''));
            if ($msg === '') $msg = $j['label'] . ($ok ? ': concluído.' : ': falhou.');
            flash($ok, $msg, stripos($msg, 'password') !== false || stripos($msg, 'chave') !== false || stripos($msg, 'recupera') !== false);
            audit($j['label'] . ($ok ? ' — concluído' : ' — falhou'), $ok);
        } elseif (time() - (int)($j['t'] ?? 0) > 1800) {
            unset($jobs[$id]);
            flash(false, $j['label'] . ': sem resposta. No servidor: systemctl status minipainel-worker.path');
        }
    }
    $_SESSION['jobs'] = $jobs;
    return count($jobs);
}

/* ---------- limite de tentativas de login ---------- */
function rl_file(): string { return MP_RL . '/' . hash('sha256', (string)($_SERVER['REMOTE_ADDR'] ?? '')) . '.json'; }
function rl_wait(): int { $d = jload(rl_file()); $u = (int)($d['until'] ?? 0); return $u > time() ? $u - time() : 0; }
function rl_fail(): void {
    $f = rl_file();
    $d = jload($f);
    if ($d === null || time() - (int)($d['first'] ?? 0) > 900) $d = ['n' => 0, 'first' => time()];
    $d['n'] = (int)($d['n'] ?? 0) + 1;
    if ($d['n'] >= 5) $d = ['n' => 0, 'first' => time(), 'until' => time() + 600];
    @file_put_contents($f, (string)json_encode($d), LOCK_EX);
}
function rl_clear(): void { @unlink(rl_file()); }

/* ---------- estilos ---------- */
function mp_head(string $title): string {
    return '<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>' . h($title) . ' · IDDigital Hosting</title>'
        . '<script>(function(){var t=null;try{t=localStorage.getItem("mp-theme")}catch(e){}if(!t)t=matchMedia("(prefers-color-scheme: dark)").matches?"dark":"light";document.documentElement.setAttribute("data-theme",t)})();</script>'
        . mp_css();
}
function mp_css(): string {
    return <<<'CSS'
<style>
:root{--bg:#e8edf2;--card:#fff;--ink:#14222f;--ink-2:#5f6e7c;--ink-3:#8d9aa6;--line:#e1e7ed;--line-2:#edf1f5;--hover:#f6f9fb;
--side:#13283a;--side-ink:#a9b8c6;--side-on:#1f5f8b;--acc:#1f5f8b;--acc-2:#184d72;--acc-bg:#e2edf6;--acc-ink:#1f5f8b;
--field:#eef3f9;--field-line:#d8e2ec;--hl:#1f5f8b;--c1:#1f5f8b;--c2:#66a8d8;--c3:#e0a33a;
--ok:#1c6b40;--ok-bg:#e2f5ea;--err:#b3261e;--err-bg:#fdecea;--warn:#9a5b08;--warn-bg:#fdf1dc;--blue-bg:#e8ecfb;--blue-ink:#3b4fb0;--vio-bg:#f1e9fb;--vio-ink:#6a3fa8;
--shadow:0 1px 2px rgba(16,24,40,.05);--pop:0 16px 40px rgba(16,24,40,.16);color-scheme:light}
[data-theme=dark]{--bg:#0d151d;--card:#16212c;--ink:#e6edf3;--ink-2:#a3b1bf;--ink-3:#728191;--line:#253342;--line-2:#1e2b38;--hover:#1a2733;
--side:#0a131b;--side-ink:#8fa1b3;--side-on:#2a6f9f;--acc:#3584bd;--acc-2:#4996cf;--acc-bg:#16334a;--acc-ink:#8cc4ec;
--field:#1b2836;--field-line:#2a3a4a;--hl:#235b84;--c1:#4a9ad3;--c2:#a8cdee;--c3:#f0b75a;
--ok:#7ed3a4;--ok-bg:#15372a;--err:#f19c95;--err-bg:#3d1b1a;--warn:#f0c27a;--warn-bg:#3a2b12;--blue-bg:#1e2a52;--blue-ink:#a9b6f5;--vio-bg:#2d2143;--vio-ink:#c8adf0;
--shadow:none;--pop:0 16px 40px rgba(0,0,0,.45);color-scheme:dark}
*{box-sizing:border-box}
html,body{margin:0}
body{font:14px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,Ubuntu,"Helvetica Neue",sans-serif;background:var(--bg);color:var(--ink);-webkit-font-smoothing:antialiased}
a{color:var(--acc-ink)}
:focus-visible{outline:2px solid var(--acc);outline-offset:2px}
svg.i{width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;flex:none}
.sr-only{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
.app{display:grid;grid-template-columns:240px minmax(0,1fr);min-height:100vh}
.side{position:sticky;top:0;height:100vh;background:var(--side);color:var(--side-ink);display:flex;flex-direction:column;gap:2px;padding:18px 14px}
.brand{display:flex;align-items:center;gap:10px;color:#fff;font-weight:650;font-size:17px;padding:2px 10px 22px;text-decoration:none}
.logo{width:32px;height:32px;border-radius:9px;background:var(--acc);display:grid;place-items:center;color:#fff}
.nav a{display:flex;align-items:center;gap:12px;padding:10px 12px;border-radius:9px;color:var(--side-ink);text-decoration:none;font-weight:500}
.nav a:hover{color:#fff;background:rgba(255,255,255,.04)}
.nav a.on{background:var(--side-on);color:#fff}
.nav a.on svg{color:#5fd0d1}
.nav a svg.tail{width:14px;height:14px;margin-left:auto;opacity:.6}
.side-foot{margin-top:auto;border-top:1px solid rgba(255,255,255,.08);padding:14px 6px 0 10px;display:flex;align-items:center;justify-content:space-between;gap:8px}
.side-foot b{display:block;color:#fff;font-weight:600}
.side-foot span{font-size:12px}
.side-foot form{margin:0}
.iconbtn{display:inline-grid;place-items:center;width:38px;height:38px;border-radius:9px;border:1px solid var(--line);background:var(--card);color:var(--ink-2);cursor:pointer;text-decoration:none}
.iconbtn:hover{color:var(--ink);border-color:var(--ink-3)}
.side .iconbtn{background:transparent;border-color:rgba(255,255,255,.12);color:var(--side-ink)}
.side .iconbtn:hover{color:#fff;border-color:rgba(255,255,255,.3)}
.main{display:flex;flex-direction:column;min-width:0}
.top{display:flex;align-items:center;gap:14px;padding:24px 32px 4px}
.top .grow{flex:1;min-width:0}
.top h1{margin:0;font-size:22px;font-weight:650;letter-spacing:-.01em}
.top p{margin:2px 0 0;color:var(--ink-2);font-size:13px}
.top-actions{display:flex;align-items:center;gap:8px}
.top-actions form{margin:0}
.burger{display:none}
/* cabeçalho em dois níveis: ferramentas globais em cima, título e ação da página por baixo */
.top{display:block}
.top-bar{display:flex;align-items:center;justify-content:flex-end;gap:10px}
.page-h{display:flex;align-items:flex-end;gap:16px;margin-top:14px}
.page-h .grow{flex:1;min-width:0}
.page-act{flex:none}
.page-act:empty{display:none}
@media (max-width:900px){
  .top-bar{justify-content:space-between;gap:6px}
  .top-bar .top-actions{order:0;width:auto;flex-wrap:nowrap;gap:6px;justify-content:flex-end}
  .top-tools .chip{height:38px;min-width:38px;padding:0 9px}
  .page-h{margin-top:12px;align-items:center;gap:12px}
  .page-h .page-act{order:0;width:auto;flex-wrap:nowrap}
  .tabs .chip,.tabs .chip.prim{width:auto!important;min-width:0;padding:0 14px!important}   /* separadores: nunca em forma de botão-ícone */
}
.content{padding:18px 32px 36px;display:flex;flex-direction:column;gap:20px}
.stats{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:16px}
.stat{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px 18px;display:flex;align-items:center;gap:14px;box-shadow:var(--shadow);min-width:0}
.stat>div{min-width:0;flex:1}
.tile{width:44px;height:44px;border-radius:12px;display:grid;place-items:center;flex:none}
.tile svg.i{width:21px;height:21px}
.t-acc{background:var(--acc-bg);color:var(--acc-ink)}.t-blue{background:var(--blue-bg);color:var(--blue-ink)}.t-vio{background:var(--vio-bg);color:var(--vio-ink)}.t-warn{background:var(--warn-bg);color:var(--warn)}
.stat .k{color:var(--ink-2);font-size:13px}
.stat .v{font-size:24px;font-weight:650;line-height:1.25}
.stat .v small{font-size:13px;font-weight:500;color:var(--ink-2)}
.meter{height:5px;border-radius:3px;background:var(--line-2);overflow:hidden;margin-top:6px}
.meter i{display:block;height:100%;background:var(--acc);border-radius:3px}
.meter i.hi{background:var(--err)}
.grid2{display:grid;grid-template-columns:minmax(0,3fr) minmax(0,2fr);gap:20px;align-items:start}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;box-shadow:var(--shadow);min-width:0}
.card-h{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;padding:14px 18px;border-bottom:1px solid var(--line-2)}
.card-h h2{margin:0;font-size:15px;font-weight:650}
.card-h p{margin:0;color:var(--ink-2);font-size:13px}
.card-b{padding:18px}
.card-f{padding:12px 18px;border-top:1px solid var(--line-2);font-size:13px}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;height:38px;padding:0 16px;border-radius:9px;border:1px solid transparent;background:var(--acc);color:#fff;font:inherit;font-weight:600;cursor:pointer;text-decoration:none;white-space:nowrap}
.btn:hover{background:var(--acc-2)}
.btn.sec{background:var(--card);color:var(--ink);border-color:var(--line)}
.btn.sec:hover{border-color:var(--ink-3)}
.btn.dan{background:var(--err);color:#fff}
.btn.dan:hover{filter:brightness(.93)}
.btn.sm{height:32px;padding:0 11px;font-size:13px;border-radius:8px;gap:6px}
.btn.sm svg.i{width:15px;height:15px}
.btn:disabled{opacity:.6;cursor:wait}
.list{width:100%;border-collapse:collapse}
.list th{font-size:12px;font-weight:600;color:var(--ink-2);text-align:left;padding:10px 18px;border-bottom:1px solid var(--line-2)}
.list td{padding:12px 18px;border-bottom:1px solid var(--line-2);vertical-align:middle}
.list tr:last-child td{border-bottom:0}
.list tbody tr:hover td{background:var(--hover)}
.list .r{text-align:right}
.who{display:flex;align-items:center;gap:12px;min-width:0}
.av{width:38px;height:38px;border-radius:10px;display:grid;place-items:center;font-weight:650;flex:none;text-transform:uppercase}
.nm{font-weight:600}
.mu{color:var(--ink-2);font-size:12.5px}
.pill{display:inline-flex;align-items:center;gap:6px;padding:3px 10px;border-radius:999px;font-size:12px;font-weight:600;white-space:nowrap}
.pill::before{content:"";width:6px;height:6px;border-radius:50%;background:currentColor}
.p-ok{background:var(--ok-bg);color:var(--ok)}.p-warn{background:var(--warn-bg);color:var(--warn)}.p-off{background:var(--line-2);color:var(--ink-2)}.p-err{background:var(--err-bg);color:var(--err)}
.port{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-weight:600;background:var(--acc-bg);color:var(--acc-ink);padding:2px 8px;border-radius:6px;font-size:12.5px}
.lim{display:flex;flex-wrap:wrap;gap:4px 10px;color:var(--ink-2);font-size:12.5px}
.lim b{color:var(--ink);font-weight:600}
.links a{display:inline-flex;align-items:center;gap:5px;text-decoration:none;font-weight:500}
.links a svg.i{width:14px;height:14px}
.row-list .item{display:flex;align-items:center;gap:12px;padding:12px 18px;border-bottom:1px solid var(--line-2)}
.row-list .item:last-child{border-bottom:0}
.row-list .grow{flex:1;min-width:0}
.row-list .item>.pill:first-child{min-width:74px;justify-content:center}
.svc-acts{display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end}
.svc-acts form{margin:0}
details.dd{position:relative;display:inline-block}
details.dd>summary{list-style:none;cursor:pointer}
details.dd>summary::-webkit-details-marker{display:none}
.dd-menu{position:absolute;right:0;top:calc(100% + 6px);z-index:30;min-width:220px;background:var(--card);border:1px solid var(--line);border-radius:12px;box-shadow:var(--pop);padding:6px}
.dd-menu form{margin:0}
.dd-menu a,.dd-menu button{display:flex;align-items:center;gap:10px;width:100%;padding:9px 10px;border:0;background:none;border-radius:8px;color:var(--ink);font:inherit;text-align:left;cursor:pointer;text-decoration:none}
.dd-menu a:hover,.dd-menu button:hover{background:var(--line-2)}
.dd-menu .dan{color:var(--err)}
.dd-menu hr{border:0;border-top:1px solid var(--line-2);margin:6px 2px}
dialog{border:0;padding:0;border-radius:16px;background:var(--card);color:var(--ink);width:min(520px,calc(100vw - 24px));max-height:calc(100vh - 24px);box-shadow:var(--pop)}
dialog::backdrop{background:rgba(8,14,20,.55)}
dialog[open]{display:flex;flex-direction:column}
dialog form{display:flex;flex-direction:column;min-height:0;flex:1;margin:0}
dialog.drawer{margin:0 0 0 auto;height:100vh;max-height:100vh;width:min(480px,100vw);border-radius:16px 0 0 16px}
.dlg-h{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:18px 22px;border-bottom:1px solid var(--line-2)}
.dlg-h h3{margin:0;font-size:17px;font-weight:650}
.dlg-h p{margin:2px 0 0;color:var(--ink-2);font-size:13px}
.dlg-b{padding:20px 22px;display:grid;gap:16px;overflow:auto;flex:1;align-content:start}
.dlg-f{display:flex;justify-content:flex-end;gap:8px;padding:14px 22px;border-top:1px solid var(--line-2)}
.fld{display:flex;flex-direction:column;gap:6px;font-size:13px;color:var(--ink-2);font-weight:500}
.fld small{font-weight:400;color:var(--ink-3);font-size:12px}
.in{height:40px;padding:0 12px;border:1px solid var(--line);border-radius:9px;background:var(--card);color:var(--ink);font:inherit;width:100%}
.in:focus{outline:0;border-color:var(--acc);box-shadow:0 0 0 3px var(--acc-bg)}
.fgrid{display:grid;grid-template-columns:1fr 1fr;gap:14px}
.fsec{margin:6px 0 -4px;padding-top:14px;border-top:1px solid var(--line-2);font-size:13px;font-weight:650;color:var(--ink)}
.chk{display:flex;align-items:center;gap:10px;font-size:14px;color:var(--ink);font-weight:400}
.chk input{width:18px;height:18px;accent-color:var(--acc)}
.warnbox{padding:12px 14px;border-radius:10px;background:var(--warn-bg);color:var(--warn);font-size:13px}
.pills{display:flex;flex-wrap:wrap;gap:6px}
.pills a{padding:5px 12px;border:1px solid var(--line);border-radius:999px;color:var(--ink);text-decoration:none;font-size:13px;font-weight:500}
.pills a:hover{border-color:var(--ink-3)}
.pills a.on{background:var(--acc);border-color:var(--acc);color:#fff}
.lead{margin:0;padding:14px 18px 0;color:var(--ink-2);font-size:13px}
.exts{display:grid;grid-template-columns:repeat(auto-fill,minmax(290px,1fr));gap:12px;padding:16px 18px 18px}
.ext{display:flex;align-items:center;justify-content:space-between;gap:12px;border:1px solid var(--line);border-radius:12px;padding:12px 14px}
.ext.on{border-color:var(--ok-bg);background:var(--hover)}
.ext .d{min-width:0}
.ext .d b{display:block;font-weight:600}
.ext .d span{display:block;color:var(--ink-2);font-size:12.5px}
.ext form{display:flex;align-items:center;gap:8px;margin:0}
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chip{padding:2px 9px;border:1px solid var(--line);border-radius:6px;background:var(--hover);font-size:12px}
.empty{padding:40px 20px;text-align:center;color:var(--ink-2)}
.empty b{display:block;color:var(--ink);font-size:15px;margin-bottom:4px}
.empty .btn{margin-top:14px}
.toasts{position:fixed;top:16px;right:16px;z-index:100;display:flex;flex-direction:column;gap:10px;width:min(420px,calc(100vw - 32px))}
.toast{display:flex;gap:12px;align-items:flex-start;background:var(--card);border:1px solid var(--line);border-radius:12px;box-shadow:var(--pop);padding:12px 12px 12px 14px}
.toast .ti{width:26px;height:26px;border-radius:50%;display:grid;place-items:center;flex:none}
.toast .ti svg.i{width:15px;height:15px}
.toast.ok .ti{background:var(--ok-bg);color:var(--ok)}
.toast.err .ti{background:var(--err-bg);color:var(--err)}
.toast .msg{flex:1;min-width:0;white-space:pre-wrap;font-size:13.5px;padding-top:2px;overflow-wrap:anywhere}
.toast .msg.mono{font-size:12.5px}
.toast button{border:0;background:none;color:var(--ink-3);cursor:pointer;padding:2px;display:grid}
.spin{width:16px;height:16px;border:2px solid var(--line);border-top-color:var(--acc);border-radius:50%;animation:sp .8s linear infinite}
@keyframes sp{to{transform:rotate(360deg)}}
.scrim{display:none}
.login{min-height:100vh;display:grid;place-items:center;padding:24px}
.login form{width:100%;max-width:380px;background:var(--card);border:1px solid var(--line);border-radius:16px;box-shadow:var(--pop);padding:30px;display:flex;flex-direction:column;gap:16px}
.login .brand{color:var(--ink);justify-content:center;padding:0 0 6px}
.login .err{padding:10px 12px;border-radius:10px;background:var(--err-bg);color:var(--err);font-size:13px}
a.stat{color:inherit;text-decoration:none}
a.stat:hover{border-color:var(--ink-3)}
.stat.hot{border-color:var(--err)}
.stat.hot .v,.stat.hot .k{color:var(--err)}
.stats5{grid-template-columns:repeat(5,minmax(0,1fr))}
.stats5 .v small{display:block;font-size:12.5px;line-height:1.4;margin-top:2px}
.stats5 .v small,.stats5 .mu{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.stats5 .mu{font-size:12.5px}
@media (max-width:1600px) and (min-width:1181px){.stats5 .tile{display:none}}
.grid2e{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:20px;align-items:start}
.legend{display:flex;gap:14px;flex-wrap:wrap;color:var(--ink-2);font-size:12.5px;margin-right:auto}
.legend i{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:6px;vertical-align:-1px}
.legend i.dash{background:none;border-top:2px dashed var(--err);height:0;width:14px;border-radius:0;vertical-align:3px;opacity:.7}
.chart{display:grid;grid-template-columns:60px minmax(0,1fr);grid-template-rows:200px 26px;padding:18px 20px 10px 0}
.ch-y{position:relative}
.ch-y span{position:absolute;right:10px;transform:translateY(-50%);font-size:11.5px;color:var(--ink-3);white-space:nowrap}
.ch-plot{position:relative;border-left:1px solid var(--line);border-bottom:1px solid var(--line)}
.ch-plot svg{position:absolute;inset:0;width:100%;height:100%;overflow:visible}
.ch-plot path.s{fill:none;stroke-width:2;vector-effect:non-scaling-stroke;stroke-linejoin:round;stroke-linecap:round}
.ch-plot line.g{stroke:var(--line-2);stroke-width:1;vector-effect:non-scaling-stroke}
.ch-plot line.ref{stroke:var(--err);stroke-width:1.5;stroke-dasharray:5 5;vector-effect:non-scaling-stroke;opacity:.6}
.ch-x{grid-column:2;position:relative}
.ch-x span{position:absolute;top:7px;transform:translateX(-50%);font-size:11.5px;color:var(--ink-3);white-space:nowrap}
.ch-x span.first{transform:none}
.ch-x span.last{transform:translateX(-100%)}
.ch-cur{position:absolute;top:0;bottom:0;width:1px;background:var(--ink-3);display:none;pointer-events:none}
.ch-tip{position:absolute;top:8px;display:none;background:var(--card);border:1px solid var(--line);border-radius:10px;box-shadow:var(--pop);padding:8px 10px;font-size:12px;pointer-events:none;white-space:nowrap;z-index:5;margin:0 10px}
.ch-tip b{display:block;margin-bottom:4px;font-weight:600}
.ch-tip i{display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:6px}
.ch-empty{position:absolute;inset:0;display:grid;place-items:center;color:var(--ink-2);font-size:13px;text-align:center;padding:0 20px}
.fm-bar{display:flex;align-items:center;gap:12px;flex-wrap:wrap;padding:14px 18px;border-bottom:1px solid var(--line-2)}
.fm-site{width:auto;min-width:170px}
.crumbs{display:flex;align-items:center;flex-wrap:wrap;gap:2px;flex:1;min-width:0;font-size:14px}
.crumbs button{border:0;background:none;color:var(--acc-ink);font:inherit;cursor:pointer;padding:4px 6px;border-radius:6px;display:inline-flex;align-items:center;gap:6px}
.crumbs button:hover{background:var(--line-2)}
.crumbs button:last-child{color:var(--ink);font-weight:600}
.crumbs .sep{color:var(--ink-3)}
.fm-tools{display:flex;gap:8px;flex-wrap:wrap}
.fm-tools label.btn{cursor:pointer}
.fm-selbar{display:flex;align-items:center;gap:8px;flex-wrap:wrap;padding:10px 18px;background:var(--acc-bg);color:var(--acc-ink);border-bottom:1px solid var(--line-2);font-size:13.5px;font-weight:600}
.fm-selbar[hidden]{display:none}
.fm-selbar .grow{flex:1}
.fm-drop{position:relative;min-height:240px}
.fm-drop.over{outline:2px dashed var(--acc);outline-offset:-8px;background:var(--hover)}
.fm-hint{display:none}
.fm-drop.over .fm-hint{display:grid;place-items:center;position:absolute;inset:0;font-weight:600;color:var(--acc-ink);pointer-events:none;background:rgba(18,164,166,.06)}
.fm-first{display:flex;align-items:center;gap:12px;min-width:0}
.fm-name{display:inline-flex;align-items:center;gap:10px;border:0;background:none;color:var(--ink);font:inherit;cursor:pointer;padding:0;text-align:left;min-width:0;max-width:100%}
.fm-name span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.fm-name:hover span{color:var(--acc-ink);text-decoration:underline}
svg.i.dir{color:#d99a2b}
svg.i.zip{color:var(--vio-ink)}
svg.i.code{color:var(--blue-ink)}
svg.i.file{color:var(--ink-3)}
.fm-ck{display:inline-flex;align-items:center}
.fm-ck input{width:16px;height:16px;margin:0;accent-color:var(--acc)}
.fm-list th:first-child{display:flex;align-items:center;gap:12px}
.fm-list tr.sel td{background:var(--acc-bg)}
.fm-menu{position:fixed;z-index:70;min-width:220px;background:var(--card);border:1px solid var(--line);border-radius:12px;box-shadow:var(--pop);padding:6px}
.fm-menu[hidden]{display:none}
.fm-menu button{display:flex;align-items:center;gap:10px;width:100%;padding:9px 10px;border:0;background:none;border-radius:8px;color:var(--ink);font:inherit;text-align:left;cursor:pointer}
.fm-menu button:hover{background:var(--line-2)}
.fm-menu .dan{color:var(--err)}
.fm-menu hr{border:0;border-top:1px solid var(--line-2);margin:6px 2px}
.ups{position:fixed;right:16px;bottom:16px;z-index:90;width:min(420px,calc(100vw - 32px));max-height:50vh;display:flex;flex-direction:column;background:var(--card);border:1px solid var(--line);border-radius:14px;box-shadow:var(--pop)}
.ups[hidden]{display:none}
.ups-h{display:flex;align-items:center;gap:10px;padding:10px 12px 10px 16px;border-bottom:1px solid var(--line-2)}
.ups-h span{flex:1;color:var(--ink-2);font-size:12.5px}
.ups-l{overflow:auto}
.up{padding:10px 16px;border-bottom:1px solid var(--line-2);font-size:13px}
.up:last-child{border-bottom:0}
.up .nm2{display:flex;justify-content:space-between;gap:10px}
.up .nm2 span:first-child{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.up .nm2 span:last-child{color:var(--ink-2);white-space:nowrap}
.up .bar{height:5px;border-radius:3px;background:var(--line-2);margin-top:6px;overflow:hidden}
.up .bar i{display:block;height:100%;width:0;background:var(--acc);border-radius:3px;transition:width .2s}
.up.ok .bar i{background:#2ea36a}
.up.err .bar i{background:var(--err)}
.up.err .nm2 span:last-child{color:var(--err);white-space:normal;text-align:right}
dialog.fm-ed{width:min(1100px,100vw)}
.fm-ed .dlg-h p{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.fm-ed textarea{flex:1;min-height:0;width:100%;border:0;resize:none;padding:16px 22px;font:13px/1.55 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:var(--card);color:var(--ink);tab-size:4;outline:0;white-space:pre;overflow:auto}
.fm-ed .dlg-f{align-items:center}
.fm-ed .dlg-f .mu{flex:1}
/* ---------- tema v1.5 ---------- */
body{font-size:14.5px}
h1,h2,h3,.brand,.stat .v,.hl .v{letter-spacing:-.015em}
.app{grid-template-columns:282px minmax(0,1fr)}
.side{top:12px;margin:12px 0 12px 12px;height:calc(100vh - 24px);border-radius:24px;padding:24px 14px 18px;gap:2px;overflow-y:auto}
.brand{padding:2px 12px 16px;font-size:18px}
.logo{border-radius:11px;background:var(--side-on)}
.nav-sec{padding:18px 14px 8px;font-size:12px;font-weight:600;color:#7f95a8}
.nav a{padding:11px 14px;border-radius:13px;color:#d3dee8;font-weight:600}
.nav a:hover{background:rgba(255,255,255,.05);color:#fff}
.nav a.on{background:var(--side-on);color:#fff}
.nav a.on svg{color:#fff}
.side-foot{display:block;margin-top:auto;border-top:0;padding:16px 14px 0;color:#7f95a8;font-size:12px}
.top{padding:24px 34px 6px 30px;gap:12px;align-items:center}
.crumb{font-size:12.5px;font-weight:600;color:var(--ink-2);margin-bottom:2px}
.top h1{font-size:26px;font-weight:750}
.top p{margin-top:4px}
.top-actions{gap:10px;flex-wrap:wrap;justify-content:flex-end}
.chip{display:inline-flex;align-items:center;gap:8px;height:44px;padding:0 18px;border-radius:999px;background:var(--card);box-shadow:0 1px 2px rgba(16,40,64,.05),0 4px 14px rgba(16,40,64,.05);border:0;color:var(--ink);font:inherit;font-weight:600;cursor:pointer;text-decoration:none;white-space:nowrap}
.chip:hover{color:var(--acc-ink)}
.chip svg.i{width:17px;height:17px}
.chip.sm{height:32px;padding:0 14px;font-size:13px;box-shadow:none;background:var(--line-2)}
.chip.ghost{background:transparent;box-shadow:none;color:var(--ink-2);font-weight:500;padding:0 4px;cursor:default}
.chip.prim{background:var(--acc);color:#fff}
.chip.prim:hover{background:var(--acc-2);color:#fff}
.chip.icon{width:44px;padding:0;justify-content:center}
.chip.soft{background:var(--acc-bg);color:var(--acc-ink);box-shadow:none}
.chip.soft:hover{filter:brightness(.97)}
details.me>summary{list-style:none;padding:0 14px 0 7px}
details.me>summary::-webkit-details-marker{display:none}
.av-me{width:32px;height:32px;border-radius:50%;background:var(--acc);color:#fff;display:grid;place-items:center;font-weight:700;font-size:13px;text-transform:uppercase}
svg.i.chev{width:15px;height:15px;color:var(--ink-3)}
.content{padding:16px 34px 40px 30px;gap:24px}
.card,.stat{border:0;border-radius:24px;box-shadow:0 1px 2px rgba(16,40,64,.04),0 10px 30px rgba(16,40,64,.05)}
.card-h{padding:24px 28px;border-bottom:1px solid var(--line-2)}
.card-h h2{font-size:17px;font-weight:700}
.card-h>div>p{margin:4px 0 0}
.card-b{padding:24px 28px}
.card-f{padding:16px 28px}
.stat{padding:20px 22px}
.tile{border-radius:14px}
.btn{height:42px;border-radius:12px}
.btn.sm{height:34px;border-radius:10px}
.in{height:46px;border-radius:12px;background:var(--field);border-color:var(--field-line)}
.in:focus{background:var(--card);border-color:var(--acc);box-shadow:0 0 0 4px var(--acc-bg)}
.list th{padding:14px 28px;font-size:12.5px}
.list td{padding:16px 28px}
.row-list .item{padding:15px 28px}
.lead{padding:16px 28px 0}
.exts{padding:18px 28px 24px}
.ext{border-radius:16px}
.pill{padding:4px 12px}
.pills a{padding:7px 15px;font-weight:600}
.pills a.on{background:var(--acc);border-color:var(--acc)}
dialog{border-radius:24px}
dialog.drawer{border-radius:24px 0 0 24px}
.dlg-h,.dlg-b,.dlg-f{padding-left:26px;padding-right:26px}
.dd-menu,.fm-menu{border-radius:16px}
.toast{border-radius:16px}
.ups{border-radius:20px}
.fm-bar,.fm-selbar{padding-left:28px;padding-right:28px}
.chart{padding:22px 28px 12px 0}
.ch-plot path.a{stroke:none;fill-opacity:.1}
.ch-plot path.dot{fill:none;stroke-width:7;stroke-linecap:round;vector-effect:non-scaling-stroke}
.hero{display:grid;grid-template-columns:minmax(0,2.3fr) minmax(0,1fr);gap:24px;align-items:stretch}
.hl{background:var(--hl);color:#fff;border-radius:24px;padding:28px 30px 0;display:flex;flex-direction:column;overflow:hidden;min-height:320px;box-shadow:0 10px 30px rgba(16,40,64,.12)}
.hl .k{font-weight:700;font-size:15px;color:rgba(255,255,255,.9)}
.hl .v{font-size:60px;font-weight:800;line-height:1.05;margin-top:12px}
.hl .s{color:rgba(255,255,255,.85);font-weight:600;font-size:14px;margin-top:8px}
.hl svg{display:block;margin:auto -30px 0;width:calc(100% + 60px);height:130px}
.bars .item{display:grid;grid-template-columns:minmax(170px,1.3fr) minmax(0,1.4fr) 64px 104px 40px;gap:16px;align-items:center}
.bars .mu{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bars .num{text-align:right;font-variant-numeric:tabular-nums}
.bars .bar{height:8px;border-radius:4px;background:var(--line-2);overflow:hidden}
.bars .bar i{display:block;height:100%;background:var(--acc);border-radius:4px}
.bars .pill{justify-self:start}
.brand{display:flex;align-items:center}
.brand-logo{display:block;height:46px;width:auto;max-width:100%}
.auth-side .brand-logo{height:58px}
.cn-search{width:260px;height:40px}
.cn-hot{color:var(--err)}
.p-me{background:var(--acc-bg);color:var(--acc-ink)}
.p-me::before{display:none}
.btn.danger-o{background:var(--card);color:var(--err);border:1px solid #e3b4af}
.btn.danger-o:hover{background:var(--err-bg)}
.cron-cmd{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:460px}
.cron-when{white-space:nowrap}
.cron-fields{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:10px}
.cron-fields .in{text-align:center;padding:0 6px}
.cron-human{padding:10px 14px;border-radius:12px;background:var(--acc-bg);color:var(--acc-ink);font-weight:600;font-size:13.5px}
.cron-human.bad{background:var(--err-bg);color:var(--err)}
.cron-ta{height:auto;min-height:84px;padding:10px 12px;resize:vertical;line-height:1.5}
.cron-help{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-top:-6px}
.cron-out{margin:0;padding:18px 26px;max-height:60vh;overflow:auto;font:12.5px/1.55 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere;background:var(--hover)}
@media (max-width:900px){.cron-fields{grid-template-columns:repeat(3,minmax(0,1fr))}.cron-cmd{max-width:60vw}}
.bk-run .item{gap:16px}
.tabs{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.pager{display:flex;align-items:center;gap:6px;flex-wrap:wrap;justify-content:flex-end}
.sn-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(380px,1fr));gap:20px;align-items:start}
.sn-dot{width:12px;height:12px;border-radius:50%;flex:none;margin-top:4px}
.sn-ok{background:var(--ok)}.sn-warn{background:var(--warn)}.sn-fail{background:var(--err);box-shadow:0 0 0 4px color-mix(in srgb,var(--err) 20%,transparent)}
.sn-av{padding:8px 24px 20px}
.sn-row{display:grid;grid-template-columns:260px 1fr 80px;gap:16px;align-items:center;padding:8px 0;border-bottom:1px solid var(--line)}
.sn-n{display:flex;flex-direction:column}.sn-pc{text-align:right}
.sn-days{display:grid;grid-template-columns:repeat(30,1fr);gap:3px}
.sn-days i{height:22px;border-radius:4px;background:var(--line)}.sn-days i.g{background:var(--ok)}.sn-days i.y{background:var(--warn)}.sn-days i.r{background:var(--err)}
.sn-chk{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:6px 18px}
@media (max-width:900px){.sn-row{grid-template-columns:1fr}}
.dlg-sec{margin:18px 0 6px;font-size:14px;padding-top:14px;border-top:1px solid var(--line)}
.infobox{background:color-mix(in srgb,var(--acc) 8%,var(--card));border:1px solid var(--line);border-radius:12px;padding:10px 12px;font-size:12.5px;line-height:1.6;margin:6px 0}
/* tabelas: o texto longo (caminhos, comandos) parte-se em vez de empurrar a tabela para fora do cartão */
.card table.list{width:100%}
.card table.list td{overflow-wrap:anywhere}
.card table.list td .mono,.card table.list td code{word-break:break-word}
@media (max-width:1500px){
  .card table.list th,.card table.list td{padding-left:12px;padding-right:12px}
  .card table.list th:first-child,.card table.list td:first-child{padding-left:24px}
  .card table.list th:last-child,.card table.list td:last-child{padding-right:24px}
}
.card table.list td .cron-cmd{white-space:normal;overflow-wrap:anywhere}
.card table.list .who>div{min-width:0}
@media (max-width:1250px){.lg-tab{table-layout:auto}.lg-tab col{width:auto!important}.lg-tab th:nth-child(6),.lg-tab td:nth-child(6),.lg-tab th:nth-child(7),.lg-tab td:nth-child(7){display:none}}
.stats.lg-stats{grid-template-columns:repeat(auto-fit,minmax(190px,1fr))}
.grid3.lg-grid{grid-template-columns:repeat(auto-fit,minmax(230px,1fr));align-items:stretch}
.lg-grid .item{gap:10px}.lg-grid .item>.grow{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.lg-ban{width:34px;padding:0;justify-content:center}
.lg-grid .item>b{flex:none;text-align:right;min-width:24px}
.lg-pager{padding:14px 24px;border-top:1px solid var(--line);flex-wrap:wrap}
.au-f{display:flex;gap:10px;align-items:center;flex-wrap:wrap;padding:0 24px 16px}
.au-f .in{height:38px;width:auto}.au-f input.in{width:280px}
.au-t{table-layout:fixed;width:100%}
.au-t td:nth-child(1),.au-t td:nth-child(2),.au-t td:nth-child(3){white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
@media (max-width:900px){.au-t{table-layout:auto}.au-f input.in{width:100%}}
.bk-cfg{display:grid;grid-template-columns:1fr;gap:20px}
.bk-cfg .fgrid{grid-template-columns:repeat(auto-fit,minmax(170px,1fr))}
.up-cfg{display:grid;grid-template-columns:1fr;gap:20px}
.lg-tab{table-layout:fixed;width:100%}
.lg-tab td,.lg-tab th{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.lg-cut,.lg-ua{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.sn-t{table-layout:fixed;width:100%}
.sn-t td{vertical-align:top}
.sn-msg{overflow-wrap:anywhere;color:var(--mu)}
.sn-allok{display:flex;align-items:center;gap:10px;padding:22px 24px;color:var(--ok);font-weight:600}
.sn-tabs{display:flex;gap:8px;flex-wrap:wrap;padding:0 24px 14px}
.sn-cnt{opacity:.65;font-weight:600;margin-left:4px}
.sn-b{display:inline-block;min-width:20px;padding:0 6px;border-radius:99px;font-size:11px;line-height:18px;color:#fff;margin-left:4px;text-align:center}
.sn-b-f{background:var(--err)}.sn-b-w{background:var(--warn)}
.sn-q{height:38px;width:240px}
@media (max-width:900px){.sn-t,.lg-tab{table-layout:auto}.sn-q{width:100%}}
.dns-help>summary{display:flex;align-items:center;gap:12px;padding:18px 24px;cursor:pointer;list-style:none}
.dns-help>summary::-webkit-details-marker{display:none}
.dns-help>summary .chev{margin-left:auto;transition:transform .2s}.dns-help[open]>summary .chev{transform:rotate(180deg)}
.dns-flow{display:flex;align-items:stretch;gap:12px;padding:4px 24px 8px;flex-wrap:wrap}
.dns-step{flex:1;min-width:200px;border:1px solid var(--line);border-radius:14px;padding:14px 16px;display:flex;flex-direction:column;gap:4px}
.dns-step p{margin:4px 0 0;color:var(--mu);font-size:13px}
.dns-arrow{align-self:center;font-size:22px;color:var(--mu)}
.dns-notes{padding:8px 24px 20px;font-size:13.5px;line-height:1.6}.dns-notes p{margin:8px 0}
.dns-g{display:inline-block;font-size:11px;font-weight:700;padding:1px 8px;border-radius:99px;margin-right:4px;background:var(--line-2)}
.dns-g-site{background:color-mix(in srgb,var(--acc) 15%,transparent);color:var(--acc)}
.dns-g-email{background:color-mix(in srgb,#7c3aed 15%,transparent);color:#7c3aed}
.dns-g-certificados{background:color-mix(in srgb,var(--ok) 15%,transparent);color:var(--ok)}
@media (max-width:900px){.dns-arrow{display:none}}
.dz-prio[hidden]{display:none!important}
.dz-h{flex-wrap:wrap;gap:12px}
.dz-act{display:flex;gap:8px;flex-wrap:wrap;align-items:center}.dz-act form{margin:0}
.dd-lbl{font-size:11px;font-weight:700;color:var(--mu);text-transform:uppercase;letter-spacing:.04em;padding:8px 10px 4px}
.dz-ban{display:flex;gap:12px;align-items:flex-start;margin:0 24px 16px;padding:14px 16px;border-radius:14px;line-height:1.7}
.dz-ban.ok{background:color-mix(in srgb,var(--ok) 12%,transparent);color:var(--ok);font-weight:600;align-items:center}
.dz-ban.warn{background:color-mix(in srgb,var(--warn) 12%,transparent)}
.dz-ban.info{background:color-mix(in srgb,var(--acc) 10%,transparent);align-items:center}
.sec-t{table-layout:fixed;width:100%}.sec-t td{padding:9px 12px!important}.sec-key{overflow-wrap:anywhere}
.sec-ns{display:flex;flex-wrap:wrap;gap:8px 4px}
.sec-f:not(.custom) [data-seccustom]{display:none}
.dz-ns{display:inline-flex;gap:6px;align-items:center;margin:0 6px}.dz-ns code{font-weight:700}
.dz-add{display:grid;grid-template-columns:120px minmax(160px,1fr) minmax(220px,2fr) 110px 120px auto;gap:10px;align-items:end;padding:16px 24px;border-top:1px solid var(--line);border-bottom:1px solid var(--line);background:var(--line-2)}
.dz-add .fld{margin:0}.dz-add .btn{height:42px}
.dz-add .dz-hint{grid-column:1/-1;margin:0;font-size:12.5px}
.dz-name{display:flex;align-items:center;gap:6px}.dz-name .in{flex:1;min-width:0}.dz-name .mu{white-space:nowrap;font-size:12.5px}
.dz-filter{display:flex;gap:10px;align-items:center;padding:14px 24px}
.dz-filter .in{height:38px;width:auto}.dz-filter #dz-q{width:280px}
.dz-t{table-layout:fixed;width:100%}.dz-t td{vertical-align:middle}
.dz-auto{display:inline-block;font-size:10.5px;font-weight:700;padding:0 7px;border-radius:99px;background:var(--line-2);color:var(--mu);margin-left:6px;cursor:help}
.dz-btns{display:flex;gap:6px;justify-content:flex-end}.dz-btns form{margin:0}
@media (max-width:1100px){.dz-add{grid-template-columns:1fr 1fr}.dz-t{table-layout:auto}}
.pr-sum{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:14px;padding:18px 24px}
.pr-o{border:1px solid var(--line);border-radius:16px;padding:12px 14px}
.pr-o .nm{margin-bottom:8px;display:flex;align-items:center;justify-content:space-between;gap:8px;white-space:nowrap}
.pr-cmd{max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:12px}
@media (min-width:901px){#pr table{table-layout:fixed;width:100%}
#pr th:nth-child(1){width:80px}#pr th:nth-child(2){width:180px}#pr th:nth-child(3){width:90px}#pr th:nth-child(4){width:110px}#pr th:nth-child(5){width:80px}#pr th:nth-child(7){width:130px}}
.pager .mu{margin-right:6px}
.cc-flag{font-size:18px;line-height:1;font-family:"Segoe UI Emoji","Apple Color Emoji","Noto Color Emoji",sans-serif}
.cbar{height:6px;border-radius:99px;background:var(--line);margin:6px 0 4px;overflow:hidden}
.cbar span{display:block;height:100%;background:var(--acc)}
.ovl-on{border:1px solid var(--err);background:color-mix(in srgb,var(--err) 8%,var(--card))}
.ovl-on b{color:var(--err)}
.term-wrap{position:relative;height:calc(100vh - 260px);min-height:420px;background:#000;border-radius:0 0 24px 24px;overflow:hidden}
.term-wrap iframe{display:none;width:100%;height:100%;border:0}
.term-wait{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;gap:10px;color:#cbd5e1}
.grid3{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:20px}
@media (max-width:1100px){.grid3{grid-template-columns:1fr}}
.lg-url{display:inline-block;max-width:420px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;vertical-align:bottom}
.lg-ua{max-width:260px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.lg-raw{max-height:70vh;font-size:12px}
.lg-filters{display:flex;gap:8px;flex-wrap:wrap}
.lg-filters .in{height:38px;width:auto;min-width:120px}
.kv{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:10px 0;border-bottom:1px solid var(--line-2)}
.kv span{color:var(--ink-2)}
.dd-menu a[aria-current]{background:var(--hover);font-weight:700}
details.dd.sys .dd-menu{min-width:230px}
details.dd>summary.chip.cur,a.chip.cur{box-shadow:inset 0 0 0 2px var(--acc);color:var(--acc)}
.md-wrap{display:grid;grid-template-columns:300px minmax(0,1fr);gap:20px;align-items:start}
.md-toc{position:sticky;top:16px;max-height:calc(100vh - 32px);display:flex;flex-direction:column;overflow:hidden}
.md-toc-h{display:flex;gap:8px;padding:16px;border-bottom:1px solid var(--line)}
.md-toc-h .in{height:38px;flex:1;min-width:0}
.md-nav{overflow:auto;padding:10px 10px 16px}
.md-nav a{display:block;padding:6px 10px;border-radius:8px;color:var(--ink);text-decoration:none;font-size:13.5px;line-height:1.35}
.md-nav a:hover{background:var(--line-2)}
.md-nav a.md-n2{font-weight:700;margin-top:6px}
.md-nav a.md-n3{padding-left:22px;color:var(--mu);font-size:12.5px}
.md-nav a.on{background:var(--hover);color:var(--acc)}
.md-none{padding:0 16px 16px}
.md-body{padding:28px 36px 40px;line-height:1.65;font-size:14.5px}
.md-body .md-h1{font-size:24px;margin:0 0 6px}
.md-body h2{font-size:20px;margin:34px 0 10px;padding-top:18px;border-top:1px solid var(--line);scroll-margin-top:16px}
.md-body .md-sec:first-of-type h2{border-top:0;padding-top:0;margin-top:18px}
.md-body h3{font-size:15.5px;margin:24px 0 8px;scroll-margin-top:16px}
.md-body p{margin:0 0 12px}
.md-body code{font-family:var(--mono,ui-monospace,Menlo,Consolas,monospace);font-size:.9em;background:var(--line-2);padding:1px 6px;border-radius:6px;word-break:break-word}
.md-code{background:#0f1720;color:#d6e2ee;border-radius:12px;padding:14px 16px;overflow:auto;margin:0 0 14px;font-size:13px;line-height:1.5}
.md-code code{background:none;padding:0;color:inherit}
.md-l{margin:0 0 12px;padding-left:22px}
.md-l li{margin:4px 0}
.md-tw{overflow-x:auto;margin:0 0 16px;border:1px solid var(--line);border-radius:12px}
.md-t{width:100%;border-collapse:collapse;font-size:13.5px}
.md-t th{text-align:left;background:var(--line-2);font-weight:700;padding:9px 12px;white-space:nowrap}
.md-t td{padding:9px 12px;border-top:1px solid var(--line);vertical-align:top}
@media (max-width:1000px){.md-wrap{grid-template-columns:1fr}.md-toc{position:static;max-height:none}.md-body{padding:20px}}
.fm-pre{display:flex;align-items:center;gap:6px;flex-wrap:nowrap;white-space:nowrap;flex:0 0 auto}
.fm-pre + .crumbs{margin-left:-6px}
.fm-pre a{display:inline-flex;align-items:center;gap:6px;color:var(--ink-2);text-decoration:none;font-weight:600}
.fm-pre a:hover{color:var(--acc)}
.fm-pre span{color:var(--ink-3)}
.fm-root a.who{text-decoration:none;color:inherit}
.fm-root a.who:hover .nm{color:var(--acc)}
.wm-card .item{gap:16px}
.tabs .chip{text-decoration:none}
.bar{height:8px;border-radius:99px;background:var(--hover);overflow:hidden;margin-bottom:4px}
.bar span{display:block;height:100%;background:var(--acc);border-radius:99px}
.bar span.hot{background:var(--err)}
.dnsrec td{vertical-align:top}
.dnsval{max-width:520px;word-break:break-all;font-size:12px;user-select:all;padding:6px 8px;border-radius:8px;background:var(--hover)}
.lnk{border:0;background:none;color:var(--ink-2);font:inherit;text-decoration:underline;cursor:pointer;padding:0;display:block;margin:0 auto}
.tfa{display:grid;grid-template-columns:auto 1fr;gap:24px;align-items:center}
.tfa-qr{background:#fff;border-radius:12px;padding:6px;line-height:0;min-width:180px;min-height:180px}
.tfa-qr svg{width:180px;height:180px}
.tfa-side{display:flex;flex-direction:column;gap:12px}
.tfa-key{padding:10px 12px;border-radius:10px;background:var(--hover);font-size:15px;letter-spacing:.05em;word-break:break-all}
@media (max-width:900px){.tfa{grid-template-columns:1fr}}
.links.dom{margin-bottom:4px}
.links.dom a{font-weight:600}
svg.i.lock{width:14px;height:14px;color:#2ea36a;margin-right:4px;vertical-align:-2px}
.mode-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}
.mode{display:grid;grid-template-columns:auto 1fr;grid-template-rows:auto auto;gap:4px 14px;align-items:center;padding:18px;border:2px solid var(--line);border-radius:18px;cursor:pointer;color:var(--ink);font-weight:400}
.mode input{position:absolute;opacity:0;pointer-events:none}
.mode .tile{grid-row:1 / 3}
.mode b{font-size:16px}
.mode .mu{grid-column:2;font-size:13px}
.mode.on,.mode:has(input:checked){border-color:var(--acc);background:var(--acc-bg)}
@media (max-width:900px){.mode-grid{grid-template-columns:1fr}}
dialog{text-align:left}
.rm-grp{display:grid;gap:14px}
.rm-grp[hidden]{display:none}
.auth{background:var(--card)}
.auth-wrap{display:grid;grid-template-columns:1fr 1fr;min-height:100vh}
.auth-side{background-color:#13283a;background-image:linear-gradient(rgba(255,255,255,.035) 1px,transparent 1px),linear-gradient(90deg,rgba(255,255,255,.035) 1px,transparent 1px);background-size:48px 48px;color:#fff;padding:52px 56px;display:flex;flex-direction:column;justify-content:space-between;gap:40px}
.auth-side .brand{color:#fff;padding:0}
.auth-side .logo{background:#1f5f8b}
.auth-hero h1{margin:0;font-size:clamp(36px,3.6vw,56px);line-height:1.08;font-weight:800;letter-spacing:-.025em}
.auth-hero h1 span{color:#9db8cf}
.auth-hero p{margin:20px 0 0;max-width:460px;color:#c6d3de;font-size:17px;line-height:1.55}
.auth-foot{color:#8ea4b7;font-size:13px}
.auth-main{display:grid;place-items:center;padding:40px 28px;background:var(--card)}
.auth-form{width:min(380px,100%);display:flex;flex-direction:column;gap:18px}
.auth-form h2{margin:0;font-size:28px;font-weight:750;letter-spacing:-.02em}
.auth-form>p{margin:-10px 0 6px;color:var(--ink-2)}
.auth-form .fld{color:var(--ink);font-weight:600;font-size:14px}
.auth-form .btn{height:52px;border-radius:14px;font-size:15px;margin-top:4px}
.auth-form .err{padding:12px 14px;border-radius:12px;background:var(--err-bg);color:var(--err);font-size:13.5px}
@media (max-width:1180px){.stats{grid-template-columns:repeat(2,minmax(0,1fr))}.grid2{grid-template-columns:1fr}.stats5{grid-template-columns:repeat(3,minmax(0,1fr))}.grid2e{grid-template-columns:1fr}}
@media (max-width:900px){
  .app{grid-template-columns:1fr}
  .side{position:fixed;left:0;top:0;bottom:0;height:auto;width:264px;z-index:60;transform:translateX(-100%);transition:transform .2s ease}
  body.nav-open .side{transform:none}
  body.nav-open .scrim{display:block;position:fixed;inset:0;background:rgba(8,14,20,.55);z-index:50}
  .burger{display:inline-grid}
  .top{padding:14px 16px 2px;gap:10px}
  .top h1{font-size:19px}
  .top p{display:none}
  .top-actions .btn .lbl{display:none}
  .top-actions .btn{width:38px;padding:0}
  .content{padding:12px 16px 28px;gap:16px}
  .stats{gap:12px}
  .stat{padding:12px;gap:10px;flex-direction:column;align-items:flex-start}
  .tile{width:36px;height:36px;border-radius:10px}
  .stat .v{font-size:20px}
  .fgrid{grid-template-columns:1fr}
  .in{font-size:16px}
  table.cards thead{display:none}
  table.cards,table.cards tbody,table.cards tr,table.cards td{display:block;width:100%}
  table.cards tr{position:relative;padding:12px 16px;border-bottom:1px solid var(--line-2)}
  table.cards tr:last-child{border-bottom:0}
  table.cards tbody tr:hover td{background:none}
  table.cards td{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:5px 0;border:0;text-align:right}
  table.cards td::before{content:attr(data-label);color:var(--ink-2);font-size:12.5px;text-align:left;flex:none}
  table.cards td.first{display:block;text-align:left;padding:0 44px 8px 0}
  table.cards td.first::before,table.cards td.act::before{content:none}
  table.cards td.act{position:absolute;top:12px;right:12px;width:auto;padding:0}
  table.cards .lim{justify-content:flex-end}
  .row-list .item{flex-wrap:wrap}
  .svc-acts{width:100%;justify-content:flex-start}
  .exts{grid-template-columns:1fr;padding:14px 16px}
  dialog.drawer{width:100vw;border-radius:0}
  .stats5{grid-template-columns:repeat(2,minmax(0,1fr))}
  .chart{grid-template-columns:44px minmax(0,1fr);grid-template-rows:160px 24px}
  .fm-site{width:100%}
  .crumbs{flex-basis:100%}
  .fm-tools{width:100%}
  .fm-tools .btn{flex:1}
  .fm-list td.first{padding-right:44px}
  .ups{right:8px;left:8px;bottom:8px;width:auto}
  .toasts{top:auto;bottom:16px;right:16px}
}
@media (max-width:420px){.stats{grid-template-columns:1fr 1fr}.stat .v small{display:block}}
@media (max-width:1180px){.hero{grid-template-columns:1fr}.hl{min-height:260px}}
@media (max-width:900px){
  .side{margin:0;top:0;height:100vh;border-radius:0 24px 24px 0}
  .top{padding:14px 16px 4px}
  .top .hide-m,.chip .lbl{display:none}
  .top{flex-wrap:wrap}
  .top-actions{order:3;width:100%;justify-content:flex-start}
  .ch-x span:nth-child(even){display:none}
  .hl{min-height:220px}
  .chip.prim,.chip{height:40px}
  .chip.prim{width:40px;padding:0;justify-content:center}
  details.me>summary{padding:0 4px}
  .content{padding:12px 16px 28px;gap:18px}
  .card-h,.card-b,.card-f,.row-list .item,.lead,.exts,.fm-bar,.fm-selbar{padding-left:18px;padding-right:18px}
  .chart{padding:16px 16px 10px 0}
  .hl{padding:22px 22px 0}
  .hl svg{margin:auto -22px 0;width:calc(100% + 44px)}
  .hl .v{font-size:46px}
  .bars .item{grid-template-columns:minmax(0,1fr) auto auto;gap:10px 12px}
  .bars .bar{grid-column:1 / -1;order:9}
  .bars .num{order:2}
  .auth-wrap{grid-template-columns:1fr}
  .auth-side{padding:28px 24px;gap:26px}
  .auth-hero h1{font-size:32px}
  .auth-hero p{font-size:15px}
  .auth-foot{display:none}
}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation-duration:2s!important}}
</style>
CSS;
}

function render_login(string $err, bool $two = false): void { ?>
<!doctype html>
<html lang="pt-PT">
<head><?= mp_head('Entrar') ?></head>
<body class="auth">
<div class="auth-wrap">
  <section class="auth-side">
    <span class="brand"><?= brand_logo() ?></span>
    <div class="auth-hero">
      <h1>Gerir o servidor<br><span>e todos os sites.</span></h1>
      <p>Sites, bases de dados, ficheiros e serviços, a partir de um só painel.</p>
    </div>
    <div class="auth-foot">© <?= date('Y') ?> IDDigital Hosting · v<?= h(MP_VERSION) ?></div>
  </section>
  <section class="auth-main">
    <?php if ($two): ?>
    <form method="post" action="./" class="auth-form">
      <h2>Verificação em dois passos</h2>
      <p>Introduz o código de 6 dígitos da aplicação de autenticação.</p>
      <?php if ($err !== ''): ?><div class="err"><?= h($err) ?></div><?php endif; ?>
      <?= csrf_field() ?>
      <label class="fld">Código<input class="in mono" name="code" inputmode="numeric" autocomplete="one-time-code" required autofocus maxlength="14" placeholder="123456"></label>
      <button class="btn" type="submit">Confirmar</button>
      <p class="mu" style="margin:0;font-size:13px">Sem acesso à aplicação? Usa um dos códigos de recuperação (ex.: a1b2c3-d4e5f6).</p>
    </form>
    <form method="post" action="./" style="margin-top:-8px"><?= csrf_field() ?><input type="hidden" name="a" value="cancel2fa"><button class="lnk" type="submit">Voltar</button></form>
    <?php else: ?>
    <form method="post" action="./" class="auth-form">
      <h2>Iniciar sessão</h2>
      <p>Acede ao painel de alojamento.</p>
      <?php if ($err !== ''): ?><div class="err"><?= h($err) ?></div><?php endif; ?>
      <?= csrf_field() ?>
      <label class="fld">Utilizador<input class="in" name="user" autocomplete="username" required autofocus></label>
      <label class="fld">Password<input class="in" type="password" name="pass" autocomplete="current-password" required></label>
      <button class="btn" type="submit">Entrar</button>
    </form>
    <?php endif; ?>
  </section>
</div>
</body>
</html>
<?php }

/* ---------- autenticação ---------- */
$auth  = jload(MP_AUTH);
$pages = [
    'resumo'   => ['Resumo', 'dash'],
    'recursos' => ['Recursos', 'cpu'],
    'sites'    => ['Sites', 'world'],
    'ficheiros'=> ['Ficheiros', 'folder'],
    'cron'     => ['Tarefas agendadas', 'clock'],
    'email'    => ['Email', 'mail'],
    'dns'      => ['DNS', 'dns'],
    'logs'     => ['Logs', 'logs'],
    'bd'       => ['Bases de dados', 'db'],
    'php'      => ['PHP', 'code'],
    'servicos' => ['Serviços', 'pulse'],
    'ligacoes' => ['Ligações', 'ban'],
    'backups'  => ['Backups', 'archive'],
    'auditoria'=> ['Auditoria', 'file'],
    'atualizacoes' => ['Atualizações', 'download'],
    'terminal' => ['Terminal', 'term'],
    'alertas'  => ['Alertas', 'bell'],
    'processos' => ['Processos', 'cpu'],
    'manual'   => ['Manual', 'book'],
    'sentinela' => ['Sentinela', 'shield'],
    'definicoes' => ['Definições', 'sliders'],
    'conta'    => ['Conta', 'user'],
];
$pg   = qget('p');
$page = isset($pages[$pg]) ? $pg : 'resumo';

if (!empty($_SESSION['user']) && time() - (int)($_SESSION['seen'] ?? 0) > MP_IDLE) {
    $_SESSION = [];
    session_regenerate_id(true);
}

if (qget('stats') === 'live') {
    header('Content-Type: application/json');
    if (empty($_SESSION['user'])) { http_response_code(401); echo '{}'; exit; }
    session_write_close();
    $d = @file_get_contents(MP_STATS . '/live.json');
    echo $d !== false ? $d : '{}';
    exit;
}

if (qget('stats') === 'conns') {
    header('Content-Type: application/json');
    if (empty($_SESSION['user'])) { http_response_code(401); echo '{}'; exit; }
    session_write_close();
    $cj = jload(MP_STATS . '/conns.json') ?? [];
    $byc = [];
    foreach ((array)($cj['ips'] ?? []) as $i => $r) {
        $cc = geo_cc((string)($r['ip'] ?? '')); $cj['ips'][$i]['cc'] = $cc; $cj['ips'][$i]['fl'] = cc_flag($cc); $cj['ips'][$i]['cn'] = cc_name($cc);
        $k = $cc !== '' ? $cc : '--'; $byc[$k] = $byc[$k] ?? ['cc' => $cc, 'n' => 0, 'ips' => 0, 'fl' => cc_flag($cc), 'cn' => cc_name($cc)];
        $byc[$k]['n'] += (int)($r['n'] ?? 0); $byc[$k]['ips']++;
    }
    usort($byc, function ($a, $b) { return $b['n'] <=> $a['n']; });
    $cj['countries'] = array_values($byc);
    $cj['ovl'] = jload(MP_STATS . '/overload.json') ?? ['active' => false];
    echo json_encode($cj, JSON_UNESCAPED_UNICODE);
    exit;
}

if (qget('dnsexport') !== '') {
    if (empty($_SESSION['user'])) { http_response_code(401); exit; }
    $st0 = jload(MP_STATE) ?? []; $dn0 = (array)($st0['dns'] ?? []); $ze = strtolower(qget('dnsexport')); $zz = null;
    foreach ((array)($dn0['zones'] ?? []) as $z0) { if ((string)$z0['name'] === $ze) $zz = $z0; }
    if ($zz === null) { http_response_code(404); exit('Zona não encontrada.'); }
    $fq = function ($v) { return substr($v, -1) === '.' ? $v : $v . '.'; };
    $o = "; Zona $ze — exportada do IDDigital Hosting em " . gmdate('Y-m-d H:i') . " UTC\n\$ORIGIN $ze.\n\$TTL " . (int)($dn0['soa']['ttl'] ?? 3600) . "\n";
    $o .= "@ IN SOA " . $fq((string)$dn0['ns1']) . ' ' . $fq(str_replace('@', '.', (string)($dn0['hostmaster'] ?: 'hostmaster.' . $ze))) . ' ( ' . (int)$zz['serial'] . ' ' . (int)($dn0['soa']['refresh'] ?? 10800) . ' ' . (int)($dn0['soa']['retry'] ?? 3600) . ' ' . (int)($dn0['soa']['expire'] ?? 1209600) . ' ' . (int)($dn0['soa']['minimum'] ?? 3600) . " )\n";
    $o .= "@ IN NS " . $fq((string)$dn0['ns1']) . "\n@ IN NS " . $fq((string)$dn0['ns2']) . "\n";
    foreach ((array)$zz['records'] as $r) {
        $t = (string)$r['type']; $v = (string)$r['value']; $ttl = (int)($r['ttl'] ?? 0) >= 60 ? (int)$r['ttl'] . ' ' : '';
        if ($t === 'TXT') $v = implode(' ', array_map(function ($c) { return '"' . addcslashes($c, '"\\') . '"'; }, str_split($v, 255) ?: ['']));
        elseif (in_array($t, ['CNAME', 'NS', 'MX'], true)) $v = $fq($v);
        elseif ($t === 'SRV') { $pp = explode(' ', $v); $pp[2] = $fq($pp[2] ?? ''); $v = implode(' ', $pp); }
        if ($t === 'MX' || $t === 'SRV') $v = (int)($r['prio'] ?? 0) . ' ' . $v;
        $o .= str_pad((string)$r['name'], 24) . ' ' . $ttl . 'IN ' . $t . ' ' . $v . "\n";
    }
    header('Content-Type: text/plain; charset=utf-8'); header('Content-Disposition: attachment; filename="' . $ze . '.zone"'); echo $o; exit;
}
if (qget('manual') === 'dl') {
    if (empty($_SESSION['user'])) { http_response_code(401); exit; }
    if (!is_readable(MP_MANUAL)) { http_response_code(404); exit('Manual não encontrado.'); }
    header('Content-Type: text/markdown; charset=utf-8');
    header('Content-Disposition: attachment; filename="manual-iddigital-hosting-v' . MP_VERSION . '.md"');
    readfile(MP_MANUAL); exit;
}
if (qget('term') === 'reset') { // o terminal já terminou no servidor: esquecer a sessão e mostrar o botão Abrir
    if (!empty($_SESSION['user'])) { unset($_SESSION['term']); flash(true, 'O terminal anterior terminou. Abre um novo.'); }
    go('terminal');
}
if (qget('term') === 'view' || qget('term') === 'dl') {
    if (empty($_SESSION['user'])) { http_response_code(401); exit; }
    session_write_close();
    $tid = qget('id');
    if (!preg_match('/^\d{8}-\d{6}$/', $tid) || !is_file(MP_TERM_LOG . '/' . $tid . '.log')) { http_response_code(404); exit('Sessão não encontrada.'); }
    if (qget('term') === 'dl') {
        $ext = qget('f') === 'timing' ? 'timing' : 'log';
        $tf = MP_TERM_LOG . '/' . $tid . '.' . $ext;
        if (!is_file($tf)) { http_response_code(404); exit('Ficheiro não encontrado.'); }
        header('Content-Type: text/plain; charset=utf-8');
        header('Content-Disposition: attachment; filename="terminal-' . $tid . '.' . $ext . '"');
        header('Content-Length: ' . (string)filesize($tf));
        readfile($tf); exit;
    }
    $raw = (string)@file_get_contents(MP_TERM_LOG . '/' . $tid . '.log', false, null, 0, 20971520);
    $txt = preg_replace('/\x1b\[[0-9;?]*[ -\/]*[@-~]|\x1b\][^\x07]*(\x07|\x1b\\\\)|\x1b[()][0-9A-Za-z]|\x1b[=>]/', '', $raw) ?? $raw;
    $txt = preg_replace('/[^\x09\x0a\x20-\x7e\x80-\xff]/', '', str_replace("\r\n", "\n", $txt)) ?? $txt;
    header('Content-Type: text/html; charset=utf-8');
    echo '<!doctype html><meta charset="utf-8"><title>Sessão ' . h($tid) . '</title><style>body{margin:0;background:#0f1720;color:#d6e2ee;font:13px/1.5 ui-monospace,Menlo,Consolas,monospace}pre{margin:0;padding:20px;white-space:pre-wrap;word-break:break-word}</style><pre>' . h($txt) . '</pre>';
    exit;
}

if (qget('stats') === 'procs') {
    header('Content-Type: application/json');
    if (empty($_SESSION['user'])) { http_response_code(401); echo '{}'; exit; }
    session_write_close();
    $memt = 0; $li = (array)(jload(MP_STATS . '/live.json') ?? []); $memt = (int)($li['mem']['total'] ?? 0);
    $rows = []; $sum = [];
    foreach (log_tail(MP_STATS . '/procs.tsv', 400) as $ln) {
        $p = explode("\t", $ln); if (count($p) < 8) continue;
        [$pid, $ppid, $cpu, $rss, $et, $usr, $comm, $args] = $p;
        [$t, $lab, $site] = proc_origin($usr, $args);
        $r = ['pid' => (int)$pid, 'cpu' => (float)$cpu, 'rss' => (int)$rss, 'mem' => $memt > 0 ? round((int)$rss * 100 / $memt, 1) : 0, 'et' => (int)$et,
              'user' => $usr, 'comm' => $comm, 'args' => $args, 't' => $t, 'o' => $lab, 'site' => $site, 'prot' => proc_protected_php((int)$pid, $comm, $args, $usr)];
        $rows[] = $r;
        $k = $t === 'site' ? 'site:' . $site : $t;
        $sum[$k] = $sum[$k] ?? ['k' => $k, 't' => $t, 'o' => $t === 'site' ? 'Site ' . $site : $lab, 'cpu' => 0, 'rss' => 0, 'n' => 0];
        $sum[$k]['cpu'] += (float)$cpu; $sum[$k]['rss'] += (int)$rss; $sum[$k]['n']++;
    }
    usort($sum, function ($a, $b) { return [$b['cpu'], $b['rss']] <=> [$a['cpu'], $a['rss']]; });
    echo json_encode(['ts' => (int)@file_get_contents(MP_STATS . '/procs.ts'), 'cpus' => (int)($li['cpus'] ?? 1), 'memt' => $memt, 'rows' => $rows, 'sum' => array_values($sum)], JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}

if (qget('logs') === 'json' || qget('logs') === 'dl') {
    if (empty($_SESSION['user'])) { http_response_code(401); exit; }
    session_write_close();
    $ls = qget('site');
    if (!preg_match('/^[a-z][a-z0-9-]{0,23}$/', $ls)) { http_response_code(400); exit; }
    $ld = MP_SITE_LOGS . '/' . $ls;
    if (qget('logs') === 'dl') {
        $lf = qget('f');
        if (!preg_match('/^(access|error|php-slow)\.log(-\d{8})?(\.\d+)?(\.gz)?$/', $lf) || !is_file($ld . '/' . $lf) || is_link($ld . '/' . $lf)) { http_response_code(404); exit('Ficheiro não encontrado.'); }
        @set_time_limit(0); while (ob_get_level() > 0) ob_end_clean();
        header('Content-Type: ' . (substr($lf, -3) === '.gz' ? 'application/gzip' : 'text/plain; charset=utf-8'));
        header('Content-Length: ' . (string)filesize($ld . '/' . $lf));
        header('Content-Disposition: attachment; filename="' . $ls . '-' . $lf . '"');
        header('X-Accel-Buffering: no');
        readfile($ld . '/' . $lf); exit;
    }
    header('Content-Type: application/json; charset=utf-8');
    $lt = in_array(qget('t'), ['error', 'slow'], true) ? qget('t') : 'access'; $n = max(10, min(5000, (int)qget('n') ?: 500)); $q = mb_substr(qget('q'), 0, 200);
    if ($lt !== 'access') { echo json_encode(['lines' => log_tail($ld . '/' . ($lt === 'slow' ? 'php-slow' : 'error') . '.log', $n, $q)], JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE); exit; }
    $st = qget('st'); $ipf = qget('ip'); $rows = [];
    foreach (log_tail($ld . '/access.log', $st === '' && $ipf === '' ? $n : 200000, $q) as $ln) {
        $p = log_parse($ln); if (!$p) continue;
        if ($st !== '' && (string)intdiv($p['s'], 100) !== $st) continue;
        if ($ipf !== '' && strpos($p['ip'], $ipf) !== 0) continue;
        $p['u'] = mb_substr($p['u'], 0, 500); $p['a'] = mb_substr($p['a'], 0, 200); unset($p['r']);
        $rows[] = $p;
    }
    echo json_encode(['rows' => array_slice($rows, -$n)], JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}

if (qget('bk') === 'dl') {
    if (empty($_SESSION['user'])) { http_response_code(401); exit; }
    session_write_close();
    $bs = qget('s'); $bid = qget('id'); $bf = qget('f');
    if (!preg_match('/^([a-z][a-z0-9-]{0,23}|_bd|_sistema)$/', $bs) || !preg_match('/^\d{8}-\d{6}$/', $bid)
        || !preg_match('/^(ficheiros\.tar\.gz|sistema\.tar\.gz|bd-[a-z][a-z0-9_]{0,31}\.sql\.gz)$/', $bf)) { http_response_code(400); exit('Pedido inválido.'); }
    $path = MP_BK . '/' . $bs . '/' . $bid . '/' . $bf;
    if (!is_file($path) || !is_readable($path)) { http_response_code(404); exit('Ficheiro não encontrado.'); }
    @set_time_limit(0);
    while (ob_get_level() > 0) ob_end_clean();
    header('Content-Type: application/gzip');
    header('Content-Length: ' . (string)filesize($path));
    header('Content-Disposition: attachment; filename="' . trim($bs, '_') . '-' . $bid . '-' . $bf . '"');
    header('X-Accel-Buffering: no');
    readfile($path);
    exit;
}

if (qget('asset') === 'qr') {
    if (empty($_SESSION['user'])) { http_response_code(401); exit; }
    header('Content-Type: application/javascript; charset=utf-8');
    header('Cache-Control: private, max-age=86400');
    readfile('/opt/minipainel/qrcode.js');
    exit;
}

if (qget('poll') === '1') {
    header('Content-Type: application/json');
    if (empty($_SESSION['user'])) { http_response_code(401); echo '{"pending":0}'; exit; }
    echo json_encode(['pending' => job_collect()]);
    exit;
}

if (empty($_SESSION['user'])) {
    $err = '';
    $two = !empty($_SESSION['pre2fa']) && time() - (int)($_SESSION['pre2fa']['t'] ?? 0) < 300;
    if (!$two) unset($_SESSION['pre2fa']);
    if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
        $wait = rl_wait();
        if ($wait > 0) {
            $err = 'Demasiadas tentativas. Tenta novamente dentro de ' . (int)ceil($wait / 60) . ' min.';
        } elseif (!csrf_ok()) {
            $err = 'A sessão expirou. Tenta novamente.';
        } elseif ($two && post('a') === 'cancel2fa') {
            unset($_SESSION['pre2fa']); header('Location: ./'); exit;
        } elseif ($two) {
            $u = (string)$_SESSION['pre2fa']['u'];
            $code = post('code');
            $viaRec = false;
            $okc = $auth !== null && !empty($auth['totp']) && (totp_ok($auth, $code) || ($viaRec = recovery_use($auth, $code)));
            if ($okc) {
                rl_clear();
                unset($_SESSION['pre2fa']);
                session_regenerate_id(true);
                $_SESSION['user'] = $u; $_SESSION['seen'] = time();
                unset($_SESSION['csrf']);
                audit($viaRec ? 'Início de sessão com código de recuperação' : 'Início de sessão (2FA)', true, $u);
                if ($viaRec) flash(false, 'Entraste com um código de recuperação. Cada código só funciona uma vez: se já gastaste vários, gera novos desativando e voltando a ativar a verificação em dois passos (página Conta).');
                go('resumo');
            }
            rl_fail();
            usleep(random_int(300000, 800000));
            audit('Código de verificação em dois passos errado', false, $u);
            $err = 'Código inválido ou já utilizado.';
        } else {
            $u = post('user');
            $p = post_raw('pass');
            if ($auth !== null && hash_equals((string)($auth['user'] ?? ''), $u) && password_verify($p, (string)($auth['hash'] ?? ''))) {
                session_regenerate_id(true);
                if (!empty($auth['totp'])) {
                    $_SESSION['pre2fa'] = ['u' => $u, 't' => time()];
                    header('Location: ./'); exit;
                }
                rl_clear();
                $_SESSION['user'] = $u;
                $_SESSION['seen'] = time();
                unset($_SESSION['csrf']);
                audit('Início de sessão', true, $u);
                go('resumo');
            }
            rl_fail();
            usleep(random_int(300000, 800000));
            audit('Falha de início de sessão', false, $u);
            $err = 'Utilizador ou password incorretos.';
        }
    }
    render_login($err, $two);
    exit;
}
$_SESSION['seen'] = time();
$myIp = (string)($_SERVER['REMOTE_ADDR'] ?? '');
if ($myIp !== '' && (int)($_SESSION['ipmark'] ?? 0) < time() - 300) {
    $aif = MP_DATA . '/logs/admin-ips.json';
    $aid = jload($aif) ?? [];
    $aid[$myIp] = time();
    foreach ($aid as $k => $v) { if ((int)$v < time() - 7 * 86400) unset($aid[$k]); }
    @file_put_contents($aif, (string)json_encode($aid), LOCK_EX);
    $_SESSION['ipmark'] = time();
}

/* ---------- ações ---------- */
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    if (!csrf_ok()) { flash(false, 'Pedido inválido. Recarrega a página e tenta novamente.'); go($page); }
    $a    = post('a');
    $site = post('site');
    $php  = post('php');
    $db   = post('db');
    $back = [];
    $bad  = function (string $m) { flash(false, $m); };

    switch ($a) {
        case 'sair':
            audit('Fim de sessão');
            $_SESSION = [];
            session_destroy();
            header('Location: ./');
            exit;

        case 'refresh':
            job_submit('refresh', [], 'Atualizar estado');
            break;

        case 'site_add':
            $port = post('port');
            if (!valid_site($site)) { $bad('Nome inválido: usa minúsculas, números e "-", a começar por letra (máx. 24).'); $back = ['novo' => 'site']; break; }
            if ($port !== '' && !ctype_digit($port)) { $bad('A porta tem de ser um número.'); $back = ['novo' => 'site']; break; }
            if ($php !== '' && !preg_match(RX_PHP, $php)) { $bad('Versão de PHP inválida.'); $back = ['novo' => 'site']; break; }
            $args = [$site];
            if ($port !== '') array_push($args, '--port', $port);
            if ($php !== '') array_push($args, '--php', $php);
            foreach (LIMITS as $k => $L) {
                $v = post($k);
                if (!ctype_digit($v) || (int)$v < $L[1] || (int)$v > $L[2]) {
                    $bad($L[0] . ': indica um valor entre ' . $L[1] . ' e ' . $L[2] . ($L[3] !== '' ? ' ' . $L[3] : '') . '.');
                    $back = ['novo' => 'site'];
                    break 2;
                }
                array_push($args, $L[4], (string)(int)$v);
            }
            array_push($args, '--display-errors', post('display_errors') === '1' ? '1' : '0');
            $dl = strtolower(trim(preg_replace('/[\s,;]+/', ' ', post_raw('domains')) ?? ''));
            if ($dl !== '') {
                foreach (explode(' ', $dl) as $dd) { if (!preg_match('/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $dd)) { $bad('Domínio inválido: ' . $dd); $back = ['novo' => 'site']; break 2; } }
                array_push($args, '--domains', $dl, '--ssl', in_array(post('ssl'), ['none', 'le', 'self'], true) ? post('ssl') : 'none');
            }
            job_submit('site-add', $args, 'Criar o site ' . $site);
            break;

        case 'site_limits':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            $args = [$site];
            foreach (LIMITS as $k => $L) {
                $v = post($k);
                if (!ctype_digit($v) || (int)$v < $L[1] || (int)$v > $L[2]) {
                    $bad($L[0] . ': indica um valor entre ' . $L[1] . ' e ' . $L[2] . ($L[3] !== '' ? ' ' . $L[3] : '') . '.');
                    $back = ['limites' => $site];
                    break 2;
                }
                array_push($args, $L[4], (string)(int)$v);
            }
            array_push($args, '--display-errors', post('display_errors') === '1' ? '1' : '0');
            job_submit('site-limits', $args, 'Limites do site ' . $site);
            break;

        case 'site_del':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            job_submit('site-del', post('keep') === '1' ? [$site, '--keep-files'] : [$site], 'Apagar o site ' . $site);
            break;

        case 'site_php':
            if (!valid_site($site) || !preg_match(RX_PHP, $php)) { $bad('Pedido inválido.'); break; }
            job_submit('site-php', [$site, $php], 'Mudar ' . $site . ' para PHP ' . $php);
            break;

        case 'site_on':
        case 'site_off':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            job_submit($a === 'site_on' ? 'site-enable' : 'site-disable', [$site], ($a === 'site_on' ? 'Ativar ' : 'Desativar ') . $site);
            break;

        case 'site_perm':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            job_submit('site-fixperms', [$site], 'Corrigir permissões de ' . $site);
            break;

        case 'ext_add':
        case 'ext_del':
            $ext = post('ext');
            if (!preg_match(RX_PHP, $php) || !preg_match(RX_EXT, $ext)) { $bad('Pedido inválido.'); break; }
            job_submit($a === 'ext_add' ? 'ext-add' : 'ext-del', [$php, $ext], ($a === 'ext_add' ? 'Instalar ' : 'Remover ') . $ext . ' no PHP ' . $php);
            $back = ['v' => $php];
            break;

        case 'svc':
            $svc = post('svc'); $act = post('act');
            if (!preg_match(RX_SVC, $svc) || !in_array($act, ['reload', 'restart', 'start', 'stop'], true)) { $bad('Pedido inválido.'); break; }
            $names = ['reload' => 'Recarregar', 'restart' => 'Reiniciar', 'start' => 'Iniciar', 'stop' => 'Parar'];
            job_submit('service', [$svc, $act], $names[$act] . ' ' . $svc);
            break;

        case 'mail_enable':
            $mh = strtolower(post('host'));
            if (!preg_match('/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $mh)) { $bad('Nome do servidor de correio inválido.'); break; }
            job_submit('mail-enable', ['--host', $mh], 'Ativar o email em ' . $mh);
            break;

        case 'mail_dom_add':
        case 'mail_dom_del':
        case 'mail_dns_check':
            $md = strtolower(post('d'));
            if (!preg_match('/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $md)) { $bad('Domínio inválido.'); break; }
            $map = ['mail_dom_add' => ['mail-domain-add', 'Adicionar o domínio de email '], 'mail_dom_del' => ['mail-domain-del', 'Apagar o domínio de email '], 'mail_dns_check' => ['mail-dns-check', 'Verificar o DNS de ']];
            job_submit($map[$a][0], [$md], $map[$a][1] . $md);
            break;

        case 'mail_box_add':
            $mu = strtolower(post('user')); $md = strtolower(post('dom')); $em = $mu . '@' . $md; $pw = post_raw('pw'); $q = post('quota') !== '' ? post('quota') : '1024';
            if (!preg_match('/^[a-z0-9]([a-z0-9._+-]{0,62}[a-z0-9])?@([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $em)) { $bad('Endereço inválido.'); break; }
            if ($pw !== '' && strlen($pw) < 10) { $bad('A password tem de ter pelo menos 10 caracteres.'); break; }
            if (!ctype_digit($q) || (int)$q < 10) { $bad('Quota inválida (mínimo 10 MB).'); break; }
            $args = [$em, '--quota', $q];
            if ($pw !== '') array_push($args, '--hash', crypt($pw, '$6$' . substr(strtr(base64_encode(random_bytes(12)), '+', '.'), 0, 16) . '$'));
            job_submit('mail-box-add', $args, 'Criar a caixa de correio ' . $em);
            break;

        case 'mail_box_set':
            $em = post('email'); $pw = post_raw('pw'); $q = post('quota');
            if (!preg_match('/^[a-z0-9._+-]+@[a-z0-9.-]+$/', $em)) { $bad('Endereço inválido.'); break; }
            $args = [$em];
            if ($pw !== '') { if (strlen($pw) < 10) { $bad('A password tem de ter pelo menos 10 caracteres.'); break; } array_push($args, '--hash', crypt($pw, '$6$' . substr(strtr(base64_encode(random_bytes(12)), '+', '.'), 0, 16) . '$')); }
            if ($q !== '') { if (!ctype_digit($q) || (int)$q < 10) { $bad('Quota inválida (mínimo 10 MB).'); break; } array_push($args, '--quota', $q); }
            if (count($args) === 1) { $bad('Nada para alterar.'); break; }
            job_submit('mail-box-set', $args, 'Alterar a caixa ' . $em);
            break;

        case 'mail_box_del':
            $em = post('email');
            if (!preg_match('/^[a-z0-9._+-]+@[a-z0-9.-]+$/', $em)) { $bad('Endereço inválido.'); break; }
            job_submit('mail-box-del', [$em], 'Apagar a caixa ' . $em);
            break;

        case 'mail_alias_set':
            $al = strtolower(post('alias')); $ds = strtolower(trim(preg_replace('/[\s,;]+/', ' ', post_raw('dests')) ?? ''));
            if (!preg_match('/^([a-z0-9._+-]*)@[a-z0-9.-]+$/', $al)) { $bad('Endereço inválido.'); break; }
            foreach (array_filter(explode(' ', $ds)) as $x) { if (!filter_var($x, FILTER_VALIDATE_EMAIL)) { $bad('Destino inválido: ' . $x); break 2; } }
            job_submit('mail-alias-set', [$al, $ds], 'Encaminhamento ' . $al);
            break;

        case 'mail_alias_del':
            $al = post('alias');
            if (!preg_match('/^([a-z0-9._+-]*)@[a-z0-9.-]+$/', $al)) { $bad('Endereço inválido.'); break; }
            job_submit('mail-alias-del', [$al], 'Apagar o encaminhamento ' . $al);
            break;

        case 'mail_site':
            $op = post('op');
            if (!valid_site($site) || !in_array($op, ['limit', 'suspend', 'resume', 'purge'], true)) { $bad('Pedido inválido.'); break; }
            if ($op === 'limit') { $lm = post('limit'); if (!ctype_digit($lm) || strlen($lm) > 6) { $bad('Limite inválido.'); break; } job_submit('mail-site', [$site, '--limit', $lm], 'Limite de envio de ' . $site . ': ' . $lm . '/hora'); }
            else job_submit('mail-site', [$site, '--' . $op], ['suspend' => 'Suspender', 'resume' => 'Retomar', 'purge' => 'Apagar retidos do'][$op] . ' envio de email de ' . $site);
            $back = ['t' => 'envio'];
            break;

        case 'update_check':
            job_submit('update-check', [], 'Procurar atualizações do painel');
            break;
        case 'update_start':
            if (post('unsigned') === '1' && !reauth_ok($auth)) { $bad('Password ou código de verificação incorretos.'); break; }
            job_submit('update-start', post('unsigned') === '1' ? ['--allow-unsigned'] : [], 'Atualizar o painel' . (post('unsigned') === '1' ? ' (sem assinatura)' : ''));
            break;
        case 'update_token':
            if (!reauth_ok($auth)) { $bad('Password ou código de verificação incorretos.'); break; }
            if (post('op') === 'clear') { job_submit('update-token', ['clear'], 'Remover o token do GitHub'); break; }
            $tk = trim(post_raw('token'));
            if (!preg_match('/^(github_pat_[A-Za-z0-9_]{20,255}|gh[pousr]_[A-Za-z0-9]{20,255})$/', $tk)) { $bad('Token inválido (começa por github_pat_ ou ghp_).'); break; }
            job_submit('update-token', ['set', $tk], 'Guardar o token do GitHub');
            break;

        case 'update_key':
            if (!reauth_ok($auth)) { $bad('Password ou código de verificação incorretos.'); break; }
            if (post('op') === 'clear') { job_submit('update-key', ['clear'], 'Remover a chave das atualizações'); break; }
            $pem = trim(str_replace("\r", '', post_raw('pem')));
            if (!preg_match('/^-----BEGIN PUBLIC KEY-----\n[A-Za-z0-9+\/=\n]+\n-----END PUBLIC KEY-----$/', $pem) || strlen($pem) > 400) { $bad('Chave inválida: cola a chave pública completa (formato PEM).'); break; }
            job_submit('update-key', ['set', str_replace("\n", '\n', $pem)], 'Guardar a chave das atualizações');
            break;
        case 'update_rollback':
            $fn = post('file');
            if (!preg_match('/^\d{8}-\d{6}-v[0-9.]+\.tar\.gz$/', $fn)) { $bad('Cópia inválida.'); break; }
            if (!reauth_ok($auth)) { $bad('Password ou código de verificação incorretos.'); break; }
            job_submit('update-rollback', [$fn], 'Repor a cópia ' . $fn);
            break;
        case 'os_check':
            job_submit('os-check', [], 'Procurar atualizações do sistema');
            break;
        case 'os_start':
            job_submit('os-start', post('op') === 'security' ? ['--security'] : [], post('op') === 'security' ? 'Instalar atualizações de segurança do sistema' : 'Instalar todas as atualizações do sistema');
            break;
        case 'os_auto':
            job_submit('os-auto', [post('op') === 'off' ? 'off' : 'on'], post('op') === 'off' ? 'Desligar atualizações automáticas' : 'Ativar atualizações de segurança automáticas');
            break;
        case 'reboot':
            if (!reauth_ok($auth)) { $bad('Password ou código de verificação incorretos.'); break; }
            job_submit('reboot', [], 'Reiniciar o servidor');
            break;

        case 'site_ftp':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            if (post('off') === '1') { job_submit('site-ftp', [$site, '--off'], 'Desativar o acesso FTP/SFTP de ' . $site); break; }
            $pw = post_raw('pw');
            if ($pw !== '' && strlen($pw) < 10) { $bad('A password tem de ter pelo menos 10 caracteres.'); break; }
            $args = [$site];
            if ($pw !== '') array_push($args, '--hash', crypt($pw, '$6$' . substr(strtr(base64_encode(random_bytes(12)), '+', '.'), 0, 16) . '$'));
            job_submit('site-ftp', $args, 'Acesso FTP/SFTP de ' . $site);
            break;

        case 'ftp_settings':
            $pi = post('pasv_ip');
            if ($pi !== '' && !filter_var($pi, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) { $bad('IP inválido.'); break; }
            job_submit('ftp-settings', ['--plain', post('plain') === '1' ? 'on' : 'off', '--pasv-ip', $pi === '' ? 'none' : $pi], 'Definições do FTP');
            break;

        case 'protect_settings':
            foreach (['ssh_fails', 'panel_fails', 'auth_fails'] as $k) { $v = post($k); if (!ctype_digit($v) || (int)$v < 3 || (int)$v > 100) { $bad('O número de falhas tem de estar entre 3 e 100.'); break 2; } }
            if (!ctype_digit(post('window')) || (int)post('window') < 1 || (int)post('window') > 1440) { $bad('A janela tem de estar entre 1 e 1440 minutos.'); break; }
            foreach (['ban1', 'ban2', 'ban3'] as $k) { if (!in_array(post($k), ['15m', '1h', '6h', '24h', '7d', '30d', 'perm'], true)) { $bad('Duração inválida.'); break 2; } }
            job_submit('protect-settings', ['--ssh', post('ssh') === 'off' ? 'off' : 'on', '--ssh-fails', post('ssh_fails'), '--panel-fails', post('panel_fails'), '--auth-fails', post('auth_fails'), '--window', post('window'), '--ban1', post('ban1'), '--ban2', post('ban2'), '--ban3', post('ban3')], 'Proteção contra força bruta');
            break;

        case 'pma_settings':
            foreach (['session' => [5, 1440], 'exec' => [30, 7200], 'upload' => [8, 4096]] as $k => $lim) {
                $v = post($k); if (!ctype_digit($v) || (int)$v < $lim[0] || (int)$v > $lim[1]) { $bad('Valor fora dos limites (' . $lim[0] . ' a ' . $lim[1] . ').'); break 2; }
            }
            job_submit('pma-settings', ['--session', post('session'), '--exec', post('exec'), '--upload', post('upload')], 'Tempos e limites do phpMyAdmin');
            break;

        case 'mail_list':
            $ll = post('l'); $lo = post('op'); $lv = strtolower(trim(post('v')));
            if (!in_array($ll, ['allow', 'deny'], true) || !in_array($lo, ['add', 'del'], true)) { $bad('Pedido inválido.'); break; }
            if (!filter_var($lv, FILTER_VALIDATE_EMAIL) && !filter_var($lv, FILTER_VALIDATE_IP) && !preg_match('/^@([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $lv)) { $bad('Usa um email, @domínio ou IP.'); break; }
            job_submit('mail-list', [$ll, $lo, $lv], ($lo === 'add' ? ($ll === 'allow' ? 'Permitir ' : 'Bloquear ') : 'Remover da lista ') . $lv);
            $back = ['t' => 'spam'];
            break;

        case 'mail_queue':
            $op = post('op');
            if ($op === 'flush') job_submit('mail-queue', ['flush'], 'Reenviar a fila de correio');
            elseif ($op === 'all') job_submit('mail-queue', ['delete', 'all'], 'Esvaziar a fila de correio');
            elseif ($op === 'del' && preg_match('/^[0-9A-Za-z]{6,20}$/', post('id'))) job_submit('mail-queue', ['delete', post('id')], 'Apagar mensagem da fila');
            else $bad('Pedido inválido.');
            $back = ['t' => 'fila'];
            break;

        case 'mail_settings':
            $zs = strtolower(trim(preg_replace('/[\s,;]+/', ' ', post_raw('dnsbl')) ?? ''));
            foreach (array_filter(explode(' ', $zs)) as $z) { if (!preg_match('/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $z)) { $bad('Lista negra inválida: ' . $z); break 2; } }
            foreach (['site_limit', 'box_limit', 'auth_fails'] as $k) { if (!ctype_digit(post($k)) || strlen(post($k)) > 5) { $bad('Valores inválidos.'); break 2; } }
            if ((int)post('auth_fails') < 3) { $bad('O bloqueio por falhas de login tem de ser 3 ou mais.'); break; }
            job_submit('mail-settings', ['--dnsbl', $zs === '' ? 'none' : $zs, '--site-limit', post('site_limit'), '--box-limit', post('box_limit'), '--auth-fails', post('auth_fails')], 'Definições do antispam');
            $back = ['t' => 'antispam'];
            break;

        case 'mail_av':
            job_submit('mail-av', [post('op') === 'off' ? 'off' : 'on'], post('op') === 'off' ? 'Desativar o antivírus' : 'Ativar o antivírus');
            $back = ['t' => 'antispam'];
            break;

        case 'site_perf':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            $pc = post('cache'); $ppm = post('pm'); $pmc = post('maxch'); $psl = post('slow');
            if (!in_array($pc, ['0', '60', '300', '600', '1800', '3600'], true) || !in_array($ppm, ['ondemand', 'dynamic'], true) || !ctype_digit($pmc) || (int)$pmc < 2 || (int)$pmc > 200 || !in_array($psl, ['0', '1', '3', '5', '10'], true)) { $bad('Valores inválidos (máximo de processos entre 2 e 200).'); break; }
            $prm = post('redis_mb'); $psd = post('static_days');
            if (!in_array($prm, ['32', '64', '128', '256', '512', '1024'], true) || !in_array($psd, ['0', '7', '30', '365'], true)) { $bad('Valores inválidos.'); break; }
            job_submit('site-perf', [$site, '--cache', $pc, '--pm', $ppm, '--max-children', $pmc, '--slowlog', $psl, '--redis', post('redis') === 'on' ? 'on' : 'off', '--redis-mem', $prm,
                '--static-days', $psd, '--webp', post('webp') === 'off' ? 'off' : 'on', '--webp-auto', post('webp_auto') === '1' ? 'on' : 'off'], 'Desempenho de ' . $site);
            break;
        case 'site_webp':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            job_submit('site-webp', [$site], 'Converter as imagens de ' . $site . ' em WebP');
            break;
        case 'net_tune':
            job_submit('net-tune', [post('on') === 'off' ? 'off' : 'on'], 'Afinação de rede');
            break;
        case 'brotli':
            job_submit('brotli', [post('on') === 'off' ? 'off' : 'on'], 'Compressão Brotli');
            break;
        case 'cache_purge':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            job_submit('cache-purge', [$site], 'Limpar a cache de ' . $site);
            break;
        case 'opcache_settings':
            $om = post('mem'); $orv = post('reval');
            if (!in_array($om, ['auto', '128', '256', '512', '1024'], true) || !in_array($orv, ['0', '2', '60', '300'], true)) { $bad('Valores inválidos.'); break; }
            job_submit('opcache-settings', ['--memory', $om, '--revalidate', $orv], 'Configuração do OPcache');
            break;
        case 'opcache_reset':
            job_submit('opcache-reset', [], 'Limpar o OPcache');
            break;
        case 'db_tune':
            $bp = strtolower(post('bp')); $st = post('slow') === 'off' ? 'off' : 'on'; $stt = post('slow_t');
            if ($bp !== 'auto' && (!ctype_digit($bp) || (int)$bp < 128)) { $bad('Memória: auto ou um número igual ou superior a 128 (MB).'); break; }
            if (!ctype_digit($stt) || (int)$stt < 1 || (int)$stt > 99) { $bad('Tempo das consultas lentas entre 1 e 99 segundos.'); break; }
            job_submit('db-tune', ['--buffer', $bp, '--slow', $st, '--slow-time', $stt], 'Afinar o MariaDB');
            break;
        case 'db_slow_report':
            job_submit('db-slow-report', [], 'Atualizar as consultas lentas');
            break;

        case 'sentinel_run':
            job_submit('sentinel-run', [], 'Testar todos os serviços agora');
            break;
        case 'sentinel_settings':
            $all = array_filter(explode(' ', post('all')), function ($x) { return preg_match('/^[a-z0-9:._-]{2,80}$/', $x); });
            $on = array_filter((array)($_POST['on'] ?? []), function ($x) { return is_string($x) && preg_match('/^[a-z0-9:._-]{2,80}$/', $x); });
            $off = array_values(array_diff($all, $on));
            job_submit('sentinel-settings', ['--repair', post('repair') === 'off' ? 'off' : 'on', '--sites', post('sites') === 'off' ? 'off' : 'on', '--off', implode(' ', $off)], 'Configuração do sentinela');
            break;
        case 'proc_kill':
            $pid = post('pid');
            if (!ctype_digit($pid) || (int)$pid < 3) { $bad('Processo inválido.'); break; }
            job_submit('proc-kill', post('force') === '1' ? [$pid, '--force'] : [$pid], (post('force') === '1' ? 'Forçar o fim do processo ' : 'Terminar o processo ') . $pid);
            break;
        case 'proc_kill_site':
            if (!valid_site(post('site'))) { $bad('Site inválido.'); break; }
            job_submit('proc-kill-site', [post('site')], 'Terminar os processos do site ' . post('site'));
            break;

        case 'alerts_settings':
            $args = ['--sms', post('sms') === 'on' ? 'on' : 'off', '--email', post('email') === 'on' ? 'on' : 'off'];
            $tel = str_replace(' ', '', post('sms_to'));
            if ($tel !== '') { if (!preg_match('/^\+?[0-9]{9,15}(,\+?[0-9]{9,15})*$/', $tel)) { $bad('Número inválido (ex.: +351912345678).'); break; } array_push($args, '--sms-to', $tel); }
            if (post('sms_id') !== '') { if (!preg_match('/^[A-Za-z0-9_-]{4,80}$/', post('sms_id'))) { $bad('Token ID inválido.'); break; } array_push($args, '--sms-id', post('sms_id')); }
            if (post_raw('sms_secret') !== '') { if (!preg_match('/^[A-Za-z0-9_.+\/=-]{4,200}$/', post_raw('sms_secret'))) { $bad('Token secreto inválido.'); break; } array_push($args, '--sms-secret', post_raw('sms_secret')); }
            if (post('email_to') !== '') { if (!filter_var(post('email_to'), FILTER_VALIDATE_EMAIL)) { $bad('Email inválido.'); break; } array_push($args, '--email-to', post('email_to')); }
            foreach (['cpu' => [10, 100], 'cpu_min' => [1, 120], 'ram' => [10, 100], 'disk' => [10, 100], 'conn' => [10, 100], 'mail_pct' => [5, 500], 'mail_min' => [1, 999999]] as $k => $lim) {
                $v = post($k); if (!ctype_digit($v) || (int)$v < $lim[0] || (int)$v > $lim[1]) { $bad('Valor fora dos limites em ' . $k . ' (' . $lim[0] . ' a ' . $lim[1] . ').'); break 2; }
                array_push($args, '--' . str_replace('_', '-', $k), $v);
            }
            if (post('sms') === 'on' && $tel === '' && empty($state['alerts']['sms_to'])) { $bad('Indica o número para os SMS.'); break; }
            job_submit('alerts-settings', $args, 'Configuração dos alertas');
            break;
        case 'alerts_test':
            job_submit('alerts-test', [], 'Teste de alertas');
            break;

        case 'geo_block':
            $gc = strtoupper(post('cc')); $op = post('op') === 'del' ? 'del' : 'add';
            if (!preg_match('/^[A-Z]{2}$/', $gc)) { $bad('Escolhe um país.'); break; }
            job_submit('geo-block', [$op, $gc], ($op === 'add' ? 'Bloquear o país ' : 'Desbloquear o país ') . $gc);
            $back = ['t' => 'paises'];
            break;
        case 'geoip_update':
            job_submit('geoip-update', [], 'Atualizar a base de países');
            $back = ['t' => 'paises'];
            break;
        case 'overload_settings':
            $mx = strtolower(post('max')); $st = post('start'); $sp = post('stop'); $hc = strtoupper(post('home'));
            if ($mx !== 'auto' && (!ctype_digit($mx) || (int)$mx < 50)) { $bad('Capacidade: auto ou um número igual ou superior a 50.'); break; }
            if (!ctype_digit($st) || !ctype_digit($sp) || (int)$sp >= (int)$st || (int)$st > 99 || (int)$sp < 10) { $bad('Percentagens inválidas (a de saída tem de ser menor que a de entrada).'); break; }
            if (!preg_match('/^[A-Z]{2}$/', $hc)) { $bad('País inválido.'); break; }
            job_submit('overload-settings', [post('on') === 'off' ? '--off' : '--on', '--max', $mx, '--start', $st, '--stop', $sp, '--home', $hc], 'Limite de ligações');
            $back = ['t' => 'protecao'];
            break;

        case 'terminal_open':
            if (empty($auth['totp'])) { $bad('Ativa primeiro a verificação em dois passos (Conta).'); break; }
            if (!reauth_ok($auth)) { $bad('Password ou código de verificação incorretos.'); break; }
            $tk = bin2hex(random_bytes(16));
            $_SESSION['term'] = ['t' => $tk, 'ts' => time()];
            job_submit('terminal-start', [$tk], 'Abrir o terminal (root)');
            break;
        case 'terminal_close':
            unset($_SESSION['term']);
            job_submit('terminal-stop', [], 'Fechar o terminal');
            break;

        case 'dns_enable':
            $re = '/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/';
            $n1 = strtolower(post('ns1')); $n2 = strtolower(post('ns2')); $ip = post('ip'); $hm = post('hm');
            if (!preg_match($re, $n1) || !preg_match($re, $n2) || $n1 === $n2) { $bad('Indica dois nameservers diferentes.'); break; }
            if ($ip !== '' && !filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) { $bad('IP inválido.'); break; }
            if ($hm !== '' && !filter_var($hm, FILTER_VALIDATE_EMAIL)) { $bad('Email inválido.'); break; }
            $ip6 = post('ip6'); if ($ip6 !== '' && !filter_var($ip6, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) { $bad('IPv6 inválido.'); break; }
            $args = ['--ns1', $n1, '--ns2', $n2]; if ($ip !== '') array_push($args, '--ip', $ip); if ($ip6 !== '') array_push($args, '--ip6', $ip6); if ($hm !== '') array_push($args, '--hostmaster', $hm);
            job_submit('dns-enable', $args, 'Servidor DNS: nameservers'); $back = ['t' => 'servidor'];
            break;
        case 'dns_zone_add':
        case 'dns_zone_del':
        case 'dns_sync':
        case 'dns_check':
            $zn = strtolower(post('zone'));
            if (!preg_match('/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $zn)) { $bad('Domínio inválido.'); break; }
            $map = ['dns_zone_add' => ['dns-zone-add', 'Adicionar a zona '], 'dns_zone_del' => ['dns-zone-del', 'Apagar a zona '], 'dns_sync' => ['dns-sync', 'Sincronizar a zona '], 'dns_check' => ['dns-check', 'Verificar a delegação de ']];
            job_submit($map[$a][0], [$zn], $map[$a][1] . $zn);
            if ($a !== 'dns_zone_del') $back = ['zone' => $a === 'dns_zone_add' ? '' : $zn];
            break;
        case 'dns_rec_add':
            $zn = strtolower(post('zone')); $rt = strtoupper(post('type'));
            if (!preg_match('/^[a-z0-9.-]+$/', $zn) || !in_array($rt, ['A', 'AAAA', 'CNAME', 'MX', 'TXT', 'NS', 'SRV', 'CAA'], true)) { $bad('Pedido inválido.'); break; }
            $val = trim(str_replace(["\r", "\n"], ' ', post_raw('value')));
            if ($val === '' || strlen($val) > 2000) { $bad('Valor inválido.'); break; }
            $ttl = ctype_digit(post('ttl')) ? post('ttl') : '0'; $pr = ctype_digit(post('prio')) ? post('prio') : '10';
            job_submit('dns-rec-add', [$zn, strtolower(post('name')), $rt, $val, '--ttl', $ttl, '--prio', $pr], 'Registo ' . $rt . ' em ' . $zn);
            $back = ['zone' => $zn];
            break;
        case 'dns_rec_del':
            $zn = strtolower(post('zone')); $rid = post('id');
            if (!preg_match('/^[a-z0-9.-]+$/', $zn) || !preg_match('/^[A-Za-z0-9]{3,16}$/', $rid)) { $bad('Pedido inválido.'); break; }
            job_submit('dns-rec-del', [$zn, $rid], 'Apagar registo de ' . $zn);
            $back = ['zone' => $zn];
            break;
        case 'dns_rec_edit':
            $zn = strtolower(post('zone')); $rid = post('id'); $rt = strtoupper(post('type'));
            if (!preg_match('/^[a-z0-9.-]+$/', $zn) || !preg_match('/^[A-Za-z0-9]{3,16}$/', $rid) || !in_array($rt, ['A', 'AAAA', 'CNAME', 'MX', 'TXT', 'NS', 'SRV', 'CAA'], true)) { $bad('Pedido inválido.'); break; }
            $val = trim(str_replace(["\r", "\n"], ' ', post_raw('value')));
            if ($val === '' || strlen($val) > 2000) { $bad('Valor inválido.'); break; }
            $ttl = ctype_digit(post('ttl')) ? post('ttl') : '0'; $pr = ctype_digit(post('prio')) ? post('prio') : '10';
            job_submit('dns-rec-edit', [$zn, $rid, strtolower(post('name')), $rt, $val, '--ttl', $ttl, '--prio', $pr], 'Editar registo em ' . $zn);
            $back = ['zone' => $zn];
            break;
        case 'dns_template':
        case 'dns_reset':
        case 'dns_propagation':
        case 'dns_import':
            $zn = strtolower(post('zone'));
            if (!preg_match('/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $zn)) { $bad('Domínio inválido.'); break; }
            if ($a === 'dns_template') { $tp = post('tpl'); if (!in_array($tp, ['local', 'google', 'microsoft'], true)) { $bad('Modelo inválido.'); break; } job_submit('dns-template', [$zn, $tp], 'Email de ' . $zn . ': ' . ['local' => 'este servidor', 'google' => 'Google Workspace', 'microsoft' => 'Microsoft 365'][$tp]); }
            elseif ($a === 'dns_reset') job_submit('dns-reset', [$zn], 'Repor os registos de ' . $zn);
            elseif ($a === 'dns_propagation') job_submit('dns-propagation', [$zn], 'Propagação de ' . $zn);
            else { $zt = (string)post_raw('zonetxt'); if (trim($zt) === '' || strlen($zt) > 200000) { $bad('Cola o ficheiro de zona (até 200 KB).'); break; } job_submit('dns-import', [$zn, $zt], 'Importar registos para ' . $zn); }
            $back = ['zone' => $zn];
            break;
        case 'dns_settings':
            $sa = [];
            foreach (['ttl', 'refresh', 'retry', 'expire', 'minimum'] as $k) { $v = post($k); if (!ctype_digit($v) || (int)$v < 60 || (int)$v > 99999999) { $bad('Valores em segundos, mínimo 60.'); break 2; } array_push($sa, '--' . $k, $v); }
            job_submit('dns-settings', $sa, 'Valores predefinidos do DNS'); $back = ['t' => 'servidor'];
            break;
        case 'dns_restart':
            job_submit('dns-restart', [], 'Reiniciar o servidor DNS'); $back = ['t' => 'servidor'];
            break;
        case 'dns_secondary':
            $op = post('op');
            if ($op === 'off') { job_submit('dns-secondary', ['--provider', 'off'], 'Desligar o DNS secundário'); $back = ['t' => 'servidor']; break; }
            if ($op === 'newkey') { job_submit('dns-secondary', ['--new-key'], 'Nova chave do DNS secundário'); $back = ['t' => 'servidor']; break; }
            $prov = post('provider') === 'custom' ? 'custom' : 'he';
            $sa = ['--provider', $prov, '--tsig', post('tsig') === '1' ? 'on' : 'off', '--keep-ns2', post('keep_ns2') === '1' ? 'on' : 'off'];
            if ($prov === 'custom') {
                $ips = preg_split('/[\s,]+/', trim(post('ips')), -1, PREG_SPLIT_NO_EMPTY); $nss = preg_split('/[\s,]+/', strtolower(trim(post('ns'))), -1, PREG_SPLIT_NO_EMPTY);
                if (!$ips || !$nss) { $bad('Indica os IPs que copiam as zonas e os nameservers do serviço.'); break; }
                foreach ($ips as $x) { if (!filter_var($x, FILTER_VALIDATE_IP)) { $bad('IP inválido: ' . $x); break 2; } }
                foreach ($nss as $x) { if (!preg_match('/^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$/', $x)) { $bad('Nameserver inválido: ' . $x); break 2; } }
                array_push($sa, '--ips', implode(' ', $ips), '--notify', implode(' ', $ips), '--ns', implode(' ', $nss));
            }
            job_submit('dns-secondary', $sa, 'DNS secundário externo'); $back = ['t' => 'servidor'];
            break;
        case 'dns_server_check':
            job_submit('dns-server-check', [], 'Verificar o servidor DNS'); $back = ['t' => 'servidor'];
            break;
        case 'logs_settings':
            $ld = post('days');
            if (!ctype_digit($ld) || (int)$ld < 7 || (int)$ld > 365) { $bad('Dias entre 7 e 365.'); break; }
            job_submit('logs-settings', ['--days', $ld], 'Guardar os logs durante ' . $ld . ' dias');
            break;

        case 'panel_allow':
            $ips = array_values(array_filter(preg_split('/[\s,;]+/', post_raw('ips')) ?: []));
            foreach ($ips as $ip) { if (!valid_net($ip)) { $bad('IP ou rede inválida: ' . $ip); break 2; } }
            if ($ips) {
                $inside = false;
                foreach ($ips as $ip) { if (ip_in($myIp, $ip)) { $inside = true; break; } }
                if (!$inside && $myIp !== '127.0.0.1' && $myIp !== '::1') { $bad('O teu IP atual (' . $myIp . ') não está na lista: ficarias sem acesso ao painel. Acrescenta-o.'); break; }
            }
            job_submit('panel-allow', [$ips ? implode(' ', $ips) : 'none'], 'IPs autorizados no painel: ' . ($ips ? implode(', ', $ips) : 'todos'));
            break;

        case 'ports_access':
            job_submit('ports-access', [post('pa') === 'lan' ? 'lan' : 'all'], 'Acesso pelas portas dos sites: ' . (post('pa') === 'lan' ? 'só rede local' : 'todos'));
            break;

        case 'acct_user':
            $nu = post('newuser');
            if (!preg_match('/^[a-z][a-z0-9._-]{2,31}$/', $nu)) { $bad('Nome inválido: 3 a 32 caracteres (minúsculas, números, ".", "_" e "-"), a começar por letra.'); break; }
            if ($auth === null || !password_verify(post_raw('atual'), (string)($auth['hash'] ?? ''))) { $bad('A password atual está incorreta.'); break; }
            if (job_submit('panel-user', [$nu], 'Mudar o utilizador do painel para ' . $nu)) $_SESSION['user'] = $nu;
            break;

        case 'totp_enable':
            $sec = (string)($_SESSION['totp_new'] ?? '');
            if ($sec === '' || totp_verify($sec, post('code')) === null) { $bad('Código inválido. Confirma que a hora do telemóvel está certa e tenta de novo.'); $back = ['tfa' => 'setup']; break; }
            unset($_SESSION['totp_new']);
            job_submit('panel-2fa', ['set', $sec], 'Ativar a verificação em dois passos');
            break;

        case 'totp_disable':
            if ($auth === null || !password_verify(post_raw('atual'), (string)($auth['hash'] ?? ''))) { $bad('A password atual está incorreta.'); break; }
            if (!totp_ok($auth, post('code')) && !recovery_use($auth, post('code'))) { $bad('Código inválido.'); break; }
            job_submit('panel-2fa', ['off'], 'Desativar a verificação em dois passos');
            break;

        case 'bk_key_show':
            if ($auth === null || !password_verify(post_raw('atual'), (string)($auth['hash'] ?? ''))) { $bad('A password atual está incorreta.'); break; }
            job_submit('bk-key', [], 'Mostrar a chave dos backups');
            break;

        case 'site_domains':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            $dl = strtolower(trim(preg_replace('/[\s,;]+/', ' ', post_raw('domains')) ?? ''));
            foreach (array_filter(explode(' ', $dl)) as $dd) { if (!preg_match('/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $dd)) { $bad('Domínio inválido: ' . $dd); break 2; } }
            $ssl = in_array(post('ssl'), ['none', 'le', 'self'], true) ? post('ssl') : 'none';
            $www = in_array(post('www'), ['keep', 'www', 'root'], true) ? post('www') : 'keep';
            job_submit('site-domains', [$site, '--set', $dl, '--ssl', $ssl, '--https', post('https') === '1' ? '1' : '0', '--www', $www], 'Domínios de ' . $site);
            break;

        case 'srv_mode':
            $md = post('mode') === 'internet' ? 'internet' : 'lan'; $em = post('email');
            if ($em !== '' && !filter_var($em, FILTER_VALIDATE_EMAIL)) { $bad('Email inválido.'); break; }
            job_submit('server-mode', [$md, '--email', $em === '' ? 'none' : $em], 'Modo do servidor');
            break;

        case 'panel_domain':
            $pd = strtolower(post('domain'));
            if ($pd !== '' && !preg_match('/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/', $pd)) { $bad('Domínio inválido.'); break; }
            job_submit('panel-domain', [$pd === '' ? 'none' : $pd, '--ssl', post('ssl') === 'self' ? 'self' : 'le'], 'Domínio do painel');
            break;

        case 'bk_now':
            $tg = post('target'); $rm = post('remote');
            if ($tg !== 'all' && !preg_match('/^([a-z][a-z0-9-]{0,23}|_bd|_sistema)$/', $tg)) { $bad('Pedido inválido.'); break; }
            $args = $tg === 'all' ? [] : ['--site', $tg];
            if ($rm !== '' && preg_match('/^[a-z][a-z0-9-]{1,23}$/', $rm)) array_push($args, '--remote', $rm);
            job_submit('backup-start', $args, 'Iniciar backup');
            break;

        case 'bk_restore':
            $bs = post('s'); $bid = post('id'); $what = post('what');
            if (!preg_match('/^([a-z][a-z0-9-]{0,23}|_bd)$/', $bs) || !preg_match('/^\d{8}-\d{6}$/', $bid) || !in_array($what, ['all', 'files', 'db'], true)) { $bad('Pedido inválido.'); break; }
            if (post('ok') !== '1') { $bad('Confirma que compreendes que o conteúdo atual vai ser substituído.'); break; }
            job_submit('bk-restore', [$bs, $bid, '--what', $what], 'Repor backup de ' . ($bs === '_bd' ? 'bases de dados' : $bs));
            break;

        case 'bk_del':
            $bs = post('s'); $bid = post('id');
            if (!preg_match('/^([a-z][a-z0-9-]{0,23}|_bd|_sistema)$/', $bs) || !preg_match('/^\d{8}-\d{6}$/', $bid)) { $bad('Pedido inválido.'); break; }
            job_submit('bk-delete', [$bs, $bid], 'Apagar backup');
            break;

        case 'bk_conf':
            $tm = post('time'); $kd = post('daily'); $kw = post('weekly'); $km = post('monthly'); $rm = post('remote');
            if (!preg_match('/^([01]\d|2[0-3]):[0-5]\d$/', $tm)) { $bad('Hora inválida.'); break; }
            foreach ([$kd, $kw, $km] as $v) { if (!ctype_digit($v) || (int)$v > 999) { $bad('Os valores de retenção têm de ser números entre 0 e 999.'); break 2; } }
            if ((int)$kd < 1) { $bad('Guarda pelo menos 1 backup diário.'); break; }
            if ($rm !== 'none' && !preg_match('/^[a-z][a-z0-9-]{1,23}$/', $rm)) $rm = 'none';
            job_submit('bk-conf', [post('on') === 'on' ? '--on' : '--off', '--time', $tm, '--daily', $kd, '--weekly', $kw, '--monthly', $km, '--remote', $rm, '--encrypt', post('encrypt') === 'off' ? 'off' : 'on'], 'Agendamento dos backups');
            break;

        case 'bk_remote_add':
            $rn = post('name'); $rt = post('type');
            if (!preg_match('/^[a-z][a-z0-9-]{1,23}$/', $rn) || !in_array($rt, ['sftp', 's3', 'rclone'], true)) { $bad('Nome ou tipo inválido.'); break; }
            $args = [$rn, $rt];
            if ($rt === 'sftp') {
                $port = post('port') !== '' ? post('port') : '22';
                if (!ctype_digit($port)) { $bad('Porta inválida.'); break; }
                array_push($args, '--host', post('host'), '--port', $port, '--user', post('user'), '--path', post('path_sftp'));
                if (post_raw('pass') !== '') array_push($args, '--pass', post_raw('pass'));
                if (trim(post_raw('key')) !== '') array_push($args, '--key', str_replace(["\r\n", "\r", "\n"], '\n', trim(post_raw('key'))));
            } elseif ($rt === 's3') {
                array_push($args, '--provider', post('provider'), '--endpoint', post('endpoint'), '--region', post('region'), '--access', post('access'), '--secret', post_raw('secret'), '--bucket', post('bucket'), '--path', post('path_s3'));
            } else {
                $cfg = str_replace(["\r\n", "\r"], "\n", trim(post_raw('config')));
                array_push($args, '--config', str_replace("\n", '\n', $cfg), '--path', post('path_rc'));
            }
            job_submit('bk-remote-add', $args, 'Adicionar destino ' . $rn);
            break;

        case 'bk_remote_test':
        case 'bk_remote_del':
            $rn = post('name');
            if (!preg_match('/^[a-z][a-z0-9-]{1,23}$/', $rn)) { $bad('Destino inválido.'); break; }
            job_submit($a === 'bk_remote_test' ? 'bk-remote-test' : 'bk-remote-del', [$rn], ($a === 'bk_remote_test' ? 'Testar ' : 'Remover ') . $rn, );
            break;

        case 'db_link':
            $ls = post('site');
            if (!preg_match(RX_DB, $db) || ($ls !== 'none' && !valid_site($ls))) { $bad('Pedido inválido.'); break; }
            job_submit('db-link', [$db, $ls], 'Associar ' . $db);
            break;

        case 'cron_save':
            $cid = post('id'); $when = trim(preg_replace('/\s+/', ' ', post('when')) ?? ''); $cmdc = trim(str_replace(["\r", "\n"], ' ', post_raw('cmd')));
            $desc = substr(trim(str_replace(["\r", "\n", '|'], ' ', post_raw('desc'))), 0, 80);
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            if ($cid !== '' && !preg_match('/^[a-f0-9]{8}$/', $cid)) { $bad('Tarefa inválida.'); break; }
            if (!preg_match('/^(@(hourly|daily|weekly|monthly|yearly|annually)|(\S+ ){4}\S+)$/', $when)) { $bad('Periodicidade inválida.'); break; }
            if ($cmdc === '' || strlen($cmdc) > 2000) { $bad('O comando é obrigatório (até 2000 caracteres).'); break; }
            $args = $cid === '' ? [$site] : [$site, $cid];
            array_push($args, '--when', $when, '--cmd', $cmdc, '--label', $desc);
            job_submit($cid === '' ? 'cron-add' : 'cron-edit', $args, ($cid === '' ? 'Criar tarefa em ' : 'Atualizar tarefa de ') . $site);
            $back = $site !== '' ? ['site' => qget('site')] : [];
            break;

        case 'cron_run':
        case 'cron_on':
        case 'cron_off':
        case 'cron_del':
            $cid = post('id');
            if (!valid_site($site) || !preg_match('/^[a-f0-9]{8}$/', $cid)) { $bad('Pedido inválido.'); break; }
            $map = ['cron_run' => ['cron-run', 'Executar tarefa'], 'cron_on' => ['cron-on', 'Ativar tarefa'], 'cron_off' => ['cron-off', 'Pausar tarefa'], 'cron_del' => ['cron-del', 'Apagar tarefa']];
            job_submit($map[$a][0], [$site, $cid], $map[$a][1] . ' de ' . $site);
            $back = qget('site') !== '' ? ['site' => qget('site')] : [];
            break;

        case 'fw_block':
            $ip = post('ip'); $dur = post('dur');
            if (!valid_net($ip)) { $bad('IP ou rede inválida (ex.: 185.220.101.47 ou 45.148.10.0/24; redes de /8 a /32).'); break; }
            if (!in_array($dur, ['1h', '24h', '7d', 'perm'], true)) $dur = '24h';
            $why = substr(preg_replace('/[^\p{L}\p{N} .,:;()\/_-]/u', '', post('reason')) ?? '', 0, 80);
            job_submit('block', [$ip, '--for', $dur, '--reason', $why, '--protect', $myIp], 'Bloquear ' . $ip);
            break;

        case 'fw_unblock':
            $ip = post('ip');
            if (!valid_net($ip)) { $bad('IP inválido.'); break; }
            job_submit('unblock', [$ip], 'Desbloquear ' . $ip);
            break;

        case 'fw_allow_add':
        case 'fw_allow_del':
            $ip = post('ip');
            if (!valid_net($ip)) { $bad('IP ou rede inválida.'); break; }
            job_submit($a === 'fw_allow_add' ? 'allow-add' : 'allow-del', [$ip], ($a === 'fw_allow_add' ? 'Confiar em ' : 'Deixar de confiar em ') . $ip);
            break;

        case 'fw_auto':
            $lim = post('limit'); $dur = post('dur');
            if (!ctype_digit($lim) || (int)$lim < 10 || (int)$lim > 100000) { $bad('O limite tem de ser um número entre 10 e 100000.'); break; }
            if (!in_array($dur, ['600s', '1h', '24h', '7d'], true)) $dur = '1h';
            job_submit('fw-auto', [post('on') === 'on' ? 'on' : 'off', '--limit', (string)(int)$lim, '--duration', $dur], 'Bloqueio automático');
            break;

        case 'db_add':
            $pw = post('pw');
            if (!preg_match(RX_DB, $db)) { $bad('Nome inválido: usa minúsculas, números e "_", a começar por letra (máx. 32).'); $back = ['novo' => 'bd']; break; }
            if ($pw !== '' && !preg_match(RX_PASS, $pw)) { $bad('Password inválida: 8 a 64 caracteres (letras, números e . _ @ % + = : , ! # * -).'); $back = ['novo' => 'bd']; break; }
            $dsite = post('site');
            $dargs = $pw !== '' ? [$db, $pw] : [$db];
            if ($dsite !== '' && valid_site($dsite)) array_push($dargs, '--site', $dsite);
            job_submit('db-add', $dargs, 'Criar a base de dados ' . $db);
            break;

        case 'db_del':
            if (!preg_match(RX_DB, $db)) { $bad('Base de dados inválida.'); break; }
            job_submit('db-del', [$db], 'Apagar a base de dados ' . $db);
            break;

        case 'db_admin_pw':
            job_submit('db-admin-passwd', [], 'Password da conta de administração');
            break;

        case 'pma_update':
            job_submit('pma-update', [], 'Atualizar o phpMyAdmin');
            break;

        case 'db_pass':
            $pw = post('pw');
            if (!preg_match(RX_DB, $db)) { $bad('Base de dados inválida.'); break; }
            if ($pw !== '' && !preg_match(RX_PASS, $pw)) { $bad('Password inválida: 8 a 64 caracteres (letras, números e . _ @ % + = : , ! # * -).'); break; }
            job_submit('db-passwd', $pw !== '' ? [$db, $pw] : [$db], 'Password de ' . $db);
            break;

        case 'conta_pass':
            $cur = post_raw('atual'); $n1 = post_raw('nova'); $n2 = post_raw('repetir');
            if ($auth === null || !password_verify($cur, (string)($auth['hash'] ?? ''))) { $bad('A password atual está incorreta.'); break; }
            if (strlen($n1) < 10) { $bad('A nova password tem de ter pelo menos 10 caracteres.'); break; }
            if ($n1 !== $n2) { $bad('As passwords novas não coincidem.'); break; }
            job_submit('panel-passwd-hash', [password_hash($n1, PASSWORD_BCRYPT)], 'Password do painel');
            break;

        default:
            $bad('Ação desconhecida.');
    }
    go($page, $back);
}

/* ---------- dados para a vista ---------- */
$pending = job_collect();
$state   = jload(MP_STATE) ?? [];
$sites   = is_array($state['sites'] ?? null) ? $state['sites'] : [];
$dbs     = is_array($state['databases'] ?? null) ? $state['databases'] : [];
$phps    = is_array($state['php'] ?? null) ? $state['php'] : [];
$svcs    = is_array($state['service_list'] ?? null) ? $state['service_list'] : [];
$sys     = is_array($state['system'] ?? null) ? $state['system'] : [];
$pma     = is_array($state['pma'] ?? null) ? $state['pma'] : [];
$dbAdmin = is_array($state['db_admin'] ?? null) ? $state['db_admin'] : [];
$pmaOn   = !empty($pma['installed']);
$srv     = is_array($state['server'] ?? null) ? $state['server'] : ['mode' => 'lan'];
$isNet   = ($srv['mode'] ?? 'lan') === 'internet';
/* Fim do suporte de segurança de cada versão de PHP (php.net/supported-versions) */
function php_support(string $v): array {
    $eol = ['8.2' => '2026-12-31', '8.3' => '2027-12-31', '8.4' => '2028-12-31', '8.5' => '2029-12-31'];
    if (!isset($eol[$v])) return version_compare($v, '8.2', '<') ? ['Sem suporte de segurança', 'p-err'] : ['Suportada', 'p-ok'];
    $t = strtotime($eol[$v]);
    if ($t < time()) return ['Sem suporte de segurança', 'p-err'];
    return ['Suporte até ' . date('d/m/Y', $t), $t - time() < 180 * 86400 ? 'p-warn' : 'p-ok'];
}
function site_main_url(array $s): string {
    $doms = trim((string)($s['domains'] ?? ''));
    if ($doms === '') return '';
    $d = explode(' ', $doms)[0];
    return (!empty($s['https_ok']) ? 'https://' : 'http://') . $d . '/';
}
$defPhp  = (string)($state['default_php'] ?? '');
$host    = host_only();
$flashes = is_array($_SESSION['flash'] ?? null) ? $_SESSION['flash'] : [];
unset($_SESSION['flash']);
$jobs    = is_array($_SESSION['jobs'] ?? null) ? $_SESSION['jobs'] : [];
$active  = count(array_filter($sites, function ($s) { return !empty($s['enabled']); }));
$bySite  = [];
foreach ($sites as $s) { $v = (string)($s['php'] ?? ''); $bySite[$v] = ($bySite[$v] ?? 0) + 1; }
$svcDown = count(array_filter($svcs, function ($s) { return empty($s['active']); }));

function php_options(array $phps, string $sel): string {
    $o = '';
    foreach ($phps as $p) {
        $v = (string)($p['version'] ?? '');
        $o .= '<option value="' . h($v) . '"' . ($v === $sel ? ' selected' : '') . '>PHP ' . h($v) . '</option>';
    }
    return $o;
}
function limit_fields(array $L): string {
    $o = '<div class="fgrid">';
    foreach (LIMITS as $k => $d) {
        $o .= '<label class="fld">' . h($d[0]) . ($d[3] !== '' ? ' (' . h($d[3]) . ')' : '')
            . '<input class="in" name="' . h($k) . '" inputmode="numeric" pattern="[0-9]{1,6}" required value="' . (int)$L[$k] . '">'
            . '<small>' . h($d[5]) . ', ' . (int)$d[1] . ' a ' . (int)$d[2] . '</small></label>';
    }
    $o .= '<label class="fld">Mostrar erros no ecrã<select class="in" name="display_errors">'
        . '<option value="0"' . ($L['display_errors'] ? '' : ' selected') . '>Não (produção)</option>'
        . '<option value="1"' . ($L['display_errors'] ? ' selected' : '') . '>Sim (desenvolvimento)</option>'
        . '</select><small>display_errors</small></label></div>';
    return $o;
}
function svc_actions(array $s, array $bySite): string {
    $id = (string)($s['id'] ?? ''); $on = !empty($s['active']); $panel = !empty($s['panel']);
    $btn = function (string $act, string $icon, string $label, string $confirm = '') use ($id) {
        return '<form method="post"' . ($confirm !== '' ? ' data-confirm="' . h($confirm) . '"' : '') . '>' . act_fields('svc', ['svc' => $id, 'act' => $act])
            . '<button class="btn sm sec" type="submit">' . ic($icon) . h($label) . '</button></form>';
    };
    $o = '';
    if ($id === 'nginx') {
        $o .= $btn('reload', 'reload', 'Recarregar');
        $o .= $btn('restart', 'power', 'Reiniciar', 'Reiniciar o nginx? Os sites e o painel ficam indisponíveis durante 1 a 2 segundos.');
    } elseif ($id === 'mariadb') {
        $o .= $on ? $btn('restart', 'power', 'Reiniciar', 'Reiniciar o MariaDB? Os sites perdem a ligação à base de dados durante alguns segundos.')
                  : $btn('start', 'play', 'Iniciar');
    } else {
        $n = (int)($bySite[(string)($s['version'] ?? '')] ?? 0);
        if ($on) {
            $o .= $btn('reload', 'reload', 'Recarregar');
            $o .= $btn('restart', 'power', 'Reiniciar', 'Reiniciar ' . ($s['name'] ?? '') . '? Os pedidos em curso são interrompidos.');
            if (!$panel) $o .= $btn('stop', 'stop', 'Parar', 'Parar ' . ($s['name'] ?? '') . '? ' . ($n > 0 ? $n . ' site(s) deixam de funcionar até voltares a iniciar.' : 'Nenhum site usa esta versão.'));
        } else {
            $o .= $btn('start', 'play', 'Iniciar');
        }
    }
    return '<div class="svc-acts">' . $o . '</div>';
}
function fmt_bytes(float $b, int $dec = 1): string {
    $u = ['B', 'KB', 'MB', 'GB', 'TB']; $i = 0;
    while ($b >= 1024 && $i < 4) { $b /= 1024; $i++; }
    return number_format($b, $i === 0 ? 0 : $dec, ',', ' ') . ' ' . $u[$i];
}
function fmt_bps(float $b): string {
    $u = ['b/s', 'Kb/s', 'Mb/s', 'Gb/s']; $i = 0;
    while ($b >= 1000 && $i < 3) { $b /= 1000; $i++; }
    return number_format($b, $i === 0 ? 0 : 1, ',', ' ') . ' ' . $u[$i];
}
function fmt_int(float $n): string { return number_format($n, 0, ',', ' '); }
function fmt_dec(float $n, int $d = 1): string { return number_format($n, $d, ',', ' '); }
function live_stats(): array {
    $l = jload(MP_STATS . '/live.json') ?? [];
    $l['fresh'] = isset($l['ts']) && time() - (int)$l['ts'] < 30;
    return $l;
}
function tz_off(array $live): int {
    if (!preg_match('/^([+-])(\d{2})(\d{2})$/', (string)($live['tz'] ?? ''), $m)) return 0;
    $s = (int)$m[2] * 3600 + (int)$m[3] * 60;
    return $m[1] === '-' ? -$s : $s;
}
/* Histórico: junta o ficheiro mais grosseiro com os mais finos para o período mais recente */
function hist_load(string $range): array {
    $cfg = [
        '24h' => [86400, [['hist-1m.csv', 60]]],
        '7d'  => [604800, [['hist-10m.csv', 600], ['hist-1m.csv', 60]]],
        '30d' => [2592000, [['hist-1h.csv', 3600], ['hist-10m.csv', 600], ['hist-1m.csv', 60]]],
    ];
    if (!isset($cfg[$range])) $range = '24h';
    $from = time() - $cfg[$range][0];
    $rows = []; $after = 0;
    foreach ($cfg[$range][1] as $fc) {
        $fh = @fopen(MP_STATS . '/' . $fc[0], 'r');
        if ($fh === false) continue;
        $last = $after;
        while (($line = fgets($fh)) !== false) {
            $c = explode(',', trim($line));
            if (count($c) < 8) continue;
            $t = (int)$c[0];
            if ($t < $from || $t < $after) continue;
            $rows[] = array_map('intval', $c);
            if ($t + $fc[1] > $last) $last = $t + $fc[1];
        }
        fclose($fh);
        $after = $last;
    }
    usort($rows, function ($a, $b) { return $a[0] <=> $b[0]; });
    return ['rows' => $rows, 'from' => $from, 'to' => time(), 'range' => $range, 'step' => $cfg[$range][1][0][1]];
}
function downsample(array $rows, int $max): array {
    $n = count($rows);
    if ($n <= $max) return $rows;
    $k = (int)ceil($n / $max); $out = [];
    for ($i = 0; $i < $n; $i += $k) {
        $chunk = array_slice($rows, $i, $k); $m = count($chunk); $avg = $chunk[0];
        for ($c = 1; $c < count($avg); $c++) { $s = 0; foreach ($chunk as $r) $s += $r[$c]; $avg[$c] = $s / $m; }
        $out[] = $avg;
    }
    return $out;
}
function nice_max(float $v): float {
    if ($v <= 0) return 1;
    $e = pow(10, floor(log10($v))); $f = $v / $e;
    $n = $f <= 1 ? 1 : ($f <= 2 ? 2 : ($f <= 2.5 ? 2.5 : ($f <= 5 ? 5 : 10)));
    return $n * $e;
}
function fmt_axis(float $v, string $fmt): string {
    if ($fmt === 'pct') return fmt_int($v) . '%';
    if ($fmt === 'bps') return fmt_bps($v);
    return fmt_dec($v, $v < 10 ? 1 : 0);
}
/* Gráfico de linhas em SVG (sem bibliotecas). $series: [[nome, cor, coluna, divisor]] */
/* Curva suave monótona (Fritsch-Carlson): passa por todos os pontos sem ultrapassá-los */
function smooth_path(array $p, float $lo, float $hi): string {
    $n = count($p);
    if ($n === 0) return '';
    $d = 'M' . $p[0][0] . ' ' . $p[0][1];
    if ($n === 1) return $d . 'h1';
    $dl = []; $m = [];
    for ($i = 0; $i < $n - 1; $i++) { $dx = $p[$i + 1][0] - $p[$i][0]; $dl[$i] = $dx != 0 ? ($p[$i + 1][1] - $p[$i][1]) / $dx : 0; }
    $m[0] = $dl[0]; $m[$n - 1] = $dl[$n - 2];
    for ($i = 1; $i < $n - 1; $i++) $m[$i] = ($dl[$i - 1] * $dl[$i] <= 0) ? 0 : ($dl[$i - 1] + $dl[$i]) / 2;
    for ($i = 0; $i < $n - 1; $i++) {
        if ($dl[$i] == 0) { $m[$i] = 0; $m[$i + 1] = 0; continue; }
        $a = $m[$i] / $dl[$i]; $b = $m[$i + 1] / $dl[$i]; $q = $a * $a + $b * $b;
        if ($q > 9) { $t = 3 / sqrt($q); $m[$i] = $t * $a * $dl[$i]; $m[$i + 1] = $t * $b * $dl[$i]; }
    }
    for ($i = 0; $i < $n - 1; $i++) {
        $h3 = ($p[$i + 1][0] - $p[$i][0]) / 3;
        $c1y = max($lo, min($hi, $p[$i][1] + $m[$i] * $h3));
        $c2y = max($lo, min($hi, $p[$i + 1][1] - $m[$i + 1] * $h3));
        $d .= 'C' . round($p[$i][0] + $h3, 1) . ' ' . round($c1y, 1) . ' ' . round($p[$i + 1][0] - $h3, 1) . ' ' . round($c2y, 1) . ' ' . $p[$i + 1][0] . ' ' . $p[$i + 1][1];
    }
    return $d;
}
function sparkline(array $v): string {
    $n = count($v);
    if ($n < 2) return '';
    $mx = max(1, max($v)); $pts = [];
    foreach (array_values($v) as $i => $x) $pts[] = [round($i * 1000 / ($n - 1), 1), round(112 - ($x / $mx) * 92, 1)];
    $line = smooth_path($pts, 0, 120);
    return '<svg viewBox="0 0 1000 120" preserveAspectRatio="none" aria-hidden="true"><path d="' . $line . 'L1000 120L0 120Z" style="fill:#fff;fill-opacity:.13;stroke:none"/>'
        . '<path d="' . $line . '" style="fill:none;stroke:#fff;stroke-opacity:.9;stroke-width:2.5" vector-effect="non-scaling-stroke"/></svg>';
}
/* Pedidos por hora (24 h) somando todos os sites, e totais por site */
function traffic_24h(array $sites): array {
    $now = time(); $from = $now - 86400;
    $hours = [];
    for ($t = intdiv($from, 3600) * 3600 + 3600; $t <= intdiv($now, 3600) * 3600; $t += 3600) $hours[$t] = 0;
    $per = [];
    foreach ($sites as $s) {
        $n = (string)($s['name'] ?? '');
        if (!valid_site($n)) continue;
        $per[$n] = [0, 0.0];
        $fh = @fopen(MP_STATS . '/traffic/' . $n . '.csv', 'r');
        if ($fh === false) continue;
        while (($l = fgets($fh)) !== false) {
            $c = explode(',', trim($l));
            if (count($c) < 3 || (int)$c[0] < $from - 3599) continue;
            $per[$n][0] += (int)$c[1]; $per[$n][1] += (float)$c[2];
            if (isset($hours[(int)$c[0]])) $hours[(int)$c[0]] += (int)$c[1];
        }
        fclose($fh);
    }
    return ['hours' => $hours, 'per' => $per];
}
function chart_html(array $H, array $series, string $fmt, ?float $ymax = null, ?float $ref = null, int $tz = 0): string {
    $rows = downsample($H['rows'], 480);
    $from = (int)$H['from']; $to = (int)$H['to']; $span = max(1, $to - $from);
    $vals = []; $mx = 0.0;
    foreach ($series as $si => $s) {
        $vals[$si] = [];
        foreach ($rows as $r) { $v = $r[$s[2]] / $s[3]; $vals[$si][] = $v; if ($v > $mx) $mx = $v; }
    }
    if ($ymax === null) $ymax = nice_max(max($mx, (float)($ref ?? 0)) * 1.15);
    $gap = max(180, (int)($H['step'] ?? 60) * 3) * max(1, (int)ceil(count($H['rows']) / 480));
    $svg = '';
    for ($k = 1; $k <= 3; $k++) { $y = 50 * $k; $svg .= '<line class="g" x1="0" x2="1000" y1="' . $y . '" y2="' . $y . '"/>'; }
    if ($ref !== null && $ref < $ymax) { $y = round(200 * (1 - $ref / $ymax), 1); $svg .= '<line class="ref" x1="0" x2="1000" y1="' . $y . '" y2="' . $y . '"/>'; }
    $dots = count($rows) <= 40;
    foreach ($series as $si => $s) {
        $segs = []; $cur = []; $prevT = null;
        foreach ($rows as $i => $r) {
            $pt = [round(($r[0] - $from) / $span * 1000, 1), round(200 * (1 - min($vals[$si][$i], $ymax) / $ymax), 1)];
            if ($prevT !== null && $r[0] - $prevT > $gap) { $segs[] = $cur; $cur = []; }
            $cur[] = $pt; $prevT = $r[0];
        }
        if ($cur) $segs[] = $cur;
        $col = 'stroke:' . $s[1];
        $line = ''; $area = ''; $dotp = '';
        foreach ($segs as $seg) {
            $p = smooth_path($seg, 0, 200);
            $line .= $p;
            if ($si === 0 && count($seg) > 1) $area .= $p . 'L' . $seg[count($seg) - 1][0] . ' 200L' . $seg[0][0] . ' 200Z';
            if ($dots) foreach ($seg as $pt) $dotp .= 'M' . $pt[0] . ' ' . $pt[1] . 'h0.01';
        }
        if ($area !== '') $svg .= '<path class="a" style="fill:' . h($s[1]) . '" d="' . $area . '"/>';
        if ($line !== '') $svg .= '<path class="s" style="' . h($col) . '" d="' . $line . '"/>';
        if ($dotp !== '') $svg .= '<path class="dot" style="' . h($col) . '" d="' . $dotp . '"/>';
    }
    $ylab = '';
    for ($k = 0; $k <= 4; $k++) $ylab .= '<span style="top:' . ($k * 25) . '%">' . h(fmt_axis($ymax * (4 - $k) / 4, $fmt)) . '</span>';
    $xlab = '';
    for ($k = 0; $k <= 6; $k++) {
        $t = (int)($from + $span * $k / 6) + $tz;
        $lab = $H['range'] === '24h' ? gmdate('H:i', $t) : gmdate('d/m', $t);
        $xlab .= '<span' . ($k === 0 ? ' class="first"' : ($k === 6 ? ' class="last"' : '')) . ' style="left:' . round($k * 100 / 6, 3) . '%">' . h($lab) . '</span>';
    }
    $data = ['from' => $from, 'to' => $to, 'tz' => $tz, 'fmt' => $fmt, 't' => array_map(function ($r) { return (int)$r[0]; }, $rows), 's' => []];
    foreach ($series as $si => $s) $data['s'][] = ['n' => $s[0], 'c' => $s[1], 'v' => array_map(function ($v) { return round($v, 2); }, $vals[$si])];
    $empty = count($rows) < 2 ? '<div class="ch-empty">Ainda sem dados suficientes para este período; é gravado um ponto por minuto.</div>' : '';
    return '<div class="chart" data-chart="' . h((string)json_encode($data)) . '"><div class="ch-y">' . $ylab . '</div>'
        . '<div class="ch-plot"><svg viewBox="0 0 1000 200" preserveAspectRatio="none" aria-hidden="true">' . $svg . '</svg>'
        . '<div class="ch-cur"></div><div class="ch-tip"></div>' . $empty . '</div><div class="ch-x">' . $xlab . '</div></div>';
}
function legend(array $series): string {
    $o = '<div class="legend">';
    foreach ($series as $s) $o .= '<span><i style="background:' . h($s[1]) . '"></i>' . h($s[0]) . '</span>';
    return $o . '</div>';
}

function svc_usage(array $s, array $bySite): string {
    $id = (string)($s['id'] ?? '');
    if ($id === 'nginx') return 'Servidor web dos sites e do painel';
    if ($id === 'mariadb') return 'Bases de dados (apenas localhost)';
    $n = (int)($bySite[(string)($s['version'] ?? '')] ?? 0);
    $t = $n === 0 ? 'Nenhum site' : ($n === 1 ? '1 site' : $n . ' sites');
    return !empty($s['panel']) ? $t . ' e o próprio painel' : $t;
}

$titles = [
    'resumo'   => $sys ? trim(($sys['hostname'] ?? '') . ' · ' . ($sys['ip'] ?? '') . ' · ' . ($sys['os'] ?? '') . ' · ativo há ' . fmt_uptime((int)($sys['uptime'] ?? 0)), ' ·') : 'Estado do servidor',
    'sites'    => 'Cada site tem a sua porta e fica acessível por IP ou localhost.',
    'bd'       => 'O utilizador tem o mesmo nome da base de dados. Servidor localhost, porta 3306.',
    'php'      => 'Versões instaladas e extensões de cada versão.',
    'servicos' => 'Estado dos serviços e ações de manutenção.',
    'conta'    => 'Acesso ao painel.',
    'recursos' => 'Utilização do servidor e de cada site, atualizada a cada 5 segundos.',
    'ficheiros'=> 'Ficheiros de todos os sites e das caixas de correio, cada um gerido com o seu próprio utilizador.',
    'ligacoes' => 'Ligações abertas a este servidor, bloqueio de IPs e bloqueio automático.',
    'cron'     => 'Tarefas agendadas (cron) de cada site, como no cPanel.',
    'backups'  => 'Backups dos sites e das bases de dados, locais e remotos.',
    'definicoes' => 'Modo do servidor, acesso pelas portas, IPs autorizados, proteção contra força bruta, phpMyAdmin, FTP, Let\'s Encrypt e domínio do painel.',
    'auditoria'=> 'Quem fez o quê, quando e de onde.',
    'atualizacoes' => 'Atualizações do painel (com assinatura e reposição automática) e do sistema operativo.',
    'sentinela' => 'Testa todos os serviços a cada minuto, repara o que falha e alerta por SMS e email.',
    'manual'   => 'Tudo sobre o painel: funcionalidades, ficheiros, comandos, diagnóstico e emergências.',
    'processos' => 'Processos que consomem CPU e memória, com a origem (site, email, base de dados, sistema) e a opção de os terminar.',
    'alertas'  => 'Alertas por SMS e email: CPU, RAM, disco, ligações e volume de email.',
    'terminal' => 'Terminal do servidor (root) no browser. Exige a verificação em dois passos; as sessões ficam gravadas.',
    'email'    => 'Caixas de correio, envio dos sites e antispam.',
    'dns'      => 'DNS autoritativo: zonas dos domínios alojados neste servidor.',
    'logs'     => 'Acessos e erros de cada site: servidor web, PHP e tarefas agendadas.',
];
$groups = ['Geral' => ['resumo', 'recursos'], 'Alojamento' => ['sites', 'ficheiros', 'logs', 'cron', 'email', 'dns', 'bd', 'php'], 'Sistema' => ['servicos', 'sentinela', 'processos', 'ligacoes', 'alertas', 'terminal', 'backups', 'auditoria', 'atualizacoes']];
$section = in_array($page, ['conta', 'definicoes'], true) ? 'Sistema' : 'Geral';
foreach ($groups as $gl => $keys) { if (in_array($page, $keys, true)) $section = $gl; }
if ($page === 'manual') $section = 'Ajuda';
$lvTop = live_stats();
$today = gmdate('d/m/Y', time() + tz_off($lvTop));
$openOnLoad = '';
if (qget('novo') === 'site') $openOnLoad = 'dlg-site-new';
elseif (qget('novo') === 'bd') $openOnLoad = 'dlg-db-new';
elseif (qget('limites') !== '' && valid_site(qget('limites'))) $openOnLoad = 'dlg-lim-' . qget('limites');
?>
<!doctype html>
<html lang="pt-PT">
<head><?= mp_head($pages[$page][0]) ?></head>
<body data-pending="<?= (int)$pending ?>" data-autoopen="<?= h($openOnLoad) ?>">
<noscript><?php if ($pending > 0): ?><meta http-equiv="refresh" content="3"><?php endif; ?><div style="padding:10px 16px;background:#fdf1dc;color:#9a5b08">O painel precisa de JavaScript para as janelas e menus.</div></noscript>
<div class="app">
  <aside class="side" id="side">
    <a class="brand" href="?p=resumo" aria-label="IDDigital Hosting — Resumo"><?= brand_logo() ?></a>
    <nav class="nav">
      <?php foreach ($groups as $gl => $keys): if ($gl === 'Sistema') continue; ?>
        <div class="nav-sec"><?= h($gl) ?></div>
        <?php foreach ($keys as $k): $pd = $pages[$k]; ?>
          <a href="?p=<?= h($k) ?>"<?= $k === $page ? ' class="on" aria-current="page"' : '' ?>><?= ic($pd[1]) ?><?= h($pd[0]) ?></a>
          <?php if ($k === 'bd' && $pmaOn): ?><a href="/phpmyadmin/" target="_blank" rel="noopener"><?= ic('table') ?>phpMyAdmin<?= ic('ext', 'tail') ?></a><?php endif; ?>
        <?php endforeach; ?>
      <?php endforeach; ?>
    </nav>
    <div class="side-foot">IDDigital Hosting v<?= h(MP_VERSION) ?></div>
  </aside>
  <div class="scrim" data-nav-close></div>

  <div class="main">
    <header class="top">
      <div class="top-bar">
        <button class="iconbtn burger" type="button" data-nav-open aria-label="Abrir menu"><?= ic('menu') ?></button>
        <div class="top-actions top-tools">
        <form method="post" style="margin:0"><?= act_fields('refresh') ?><button class="chip" type="submit" title="Atualizar estado" aria-label="Atualizar estado"><?= ic('reload') ?><span class="lbl">Atualizar</span></button></form>
        <span class="chip sm hide-m">v<?= h(MP_VERSION) ?></span>
        <span class="chip ghost hide-m"><?= h($today) ?></span>
        <button class="chip icon" type="button" data-theme-toggle title="Mudar tema" aria-label="Mudar tema"><?= ic('moon') ?></button>
        <a class="chip<?= $page === 'manual' ? ' cur' : '' ?>" href="?p=manual" aria-label="Manual do utilizador"><?= ic('book') ?><span class="lbl">Manual</span></a>
        <details class="dd sys">
          <summary class="chip<?= $section === 'Sistema' && !in_array($page, ['conta', 'definicoes'], true) ? ' cur' : '' ?>" aria-label="Sistema"><?= ic('server') ?><span class="lbl">Sistema</span><?= ic('chev', 'chev') ?></summary>
          <div class="dd-menu">
            <?php foreach ($groups['Sistema'] as $k): $pd = $pages[$k]; ?>
              <a href="?p=<?= h($k) ?>"<?= $k === $page ? ' aria-current="page"' : '' ?>><?= ic($pd[1]) ?><?= h($pd[0]) ?></a>
            <?php endforeach; ?>
          </div>
        </details>
        <details class="dd me">
          <summary class="chip" aria-label="Conta"><span class="av-me"><?= h(substr((string)$_SESSION['user'], 0, 1)) ?></span><span class="lbl"><?= h($_SESSION['user']) ?></span><?= ic('chev', 'chev') ?></summary>
          <div class="dd-menu">
            <a href="?p=conta"<?= $page === 'conta' ? ' aria-current="page"' : '' ?>><?= ic('user') ?>Conta e segurança</a>
            <a href="?p=definicoes"<?= $page === 'definicoes' ? ' aria-current="page"' : '' ?>><?= ic('sliders') ?>Definições</a>
            <hr>
            <form method="post"><?= act_fields('sair') ?><button type="submit"><?= ic('out') ?>Sair</button></form>
          </div>
        </details>
        </div>
      </div>
      <div class="page-h">
        <div class="grow">
          <div class="crumb"><?= h($section) ?></div>
          <h1><?= h($pages[$page][0]) ?></h1>
          <p><?= h($titles[$page]) ?></p>
        </div>
        <div class="top-actions page-act">
        <?php if ($page === 'sites' || $page === 'resumo'): ?>
          <button class="chip prim" type="button" data-open="dlg-site-new" aria-label="Novo site"><?= ic('plus') ?><span class="lbl">Novo site</span></button>
        <?php elseif ($page === 'bd'): ?>
          <button class="chip prim" type="button" data-open="dlg-db-new" aria-label="Nova base de dados"><?= ic('plus') ?><span class="lbl">Nova base de dados</span></button>
        <?php elseif ($page === 'cron' && $sites): ?>
          <button class="chip prim" type="button" data-cron-new aria-label="Nova tarefa"><?= ic('plus') ?><span class="lbl">Nova tarefa</span></button>
        <?php elseif ($page === 'backups'): ?>
          <button class="chip prim" type="button" data-open="dlg-bk-now" aria-label="Fazer backup agora"><?= ic('archive') ?><span class="lbl">Fazer backup</span></button>
        <?php elseif ($page === 'ligacoes'): ?>
          <button class="chip prim" type="button" data-open="dlg-block" aria-label="Bloquear IP"><?= ic('ban') ?><span class="lbl">Bloquear IP</span></button>
        <?php endif; ?>
        </div>
      </div>
    </header>

    <main class="content">
<?php if (!$state): ?>
      <div class="card"><div class="empty"><b>O estado do servidor ainda não está disponível</b>Carrega em atualizar, no canto superior direito, ou corre <span class="mono">mpanel state</span> no servidor para ver o erro.</div></div>
<?php endif; ?>

<?php if ($page === 'resumo'):
    $lv = live_stats();
    $disk = (int)round($lv['fresh'] ? (float)($lv['disk']['pct'] ?? 0) : (float)($sys['disk'] ?? 0));
    $ram  = (int)round($lv['fresh'] ? (float)($lv['mem']['pct'] ?? 0) : (float)($sys['ram'] ?? 0));
    $hot  = $disk >= 90 || $ram >= 90;
    $H24  = hist_load('24h');
    $tr   = traffic_24h($sites);
    $reqTot = 0; $byTot = 0.0;
    foreach ($tr['per'] as $pv) { $reqTot += $pv[0]; $byTot += $pv[1]; }
    $reqMax = 1;
    foreach ($tr['per'] as $pv) $reqMax = max($reqMax, $pv[0]);
    $sorted = $sites;
    usort($sorted, function ($x, $y) use ($tr) { return ($tr['per'][$y['name'] ?? ''][0] ?? 0) <=> ($tr['per'][$x['name'] ?? ''][0] ?? 0); }); ?>
      <div class="hero">
        <section class="card">
          <div class="card-h"><div><h2>Utilização do servidor</h2><p>CPU e memória nas últimas 24 horas</p></div><a class="chip sm soft" href="?p=recursos">Ver recursos</a></div>
          <?= chart_html($H24, [['CPU', 'var(--c1)', 1, 10], ['Memória', 'var(--c2)', 2, 10]], 'pct', 100, null, tz_off($lv)) ?>
        </section>
        <section class="hl">
          <div class="k">Pedidos nas últimas 24 horas</div>
          <div class="v"><?= h(fmt_int($reqTot)) ?></div>
          <div class="s"><?= h(fmt_bytes($byTot)) ?> transferidos · <?= $active ?> de <?= count($sites) ?> sites ativos</div>
          <?= sparkline(array_values($tr['hours'])) ?>
        </section>
      </div>

      <section class="stats">
        <div class="stat"><span class="tile t-acc"><?= ic('world') ?></span><div><div class="k">Sites ativos</div><div class="v"><?= $active ?> <small>de <?= count($sites) ?></small></div></div></div>
        <div class="stat"><span class="tile t-blue"><?= ic('db') ?></span><div><div class="k">Bases de dados</div><div class="v"><?= count($dbs) ?></div></div></div>
        <div class="stat"><span class="tile t-vio"><?= ic('code') ?></span><div><div class="k">Versões de PHP</div><div class="v"><?= count($phps) ?> <small><?= $defPhp !== '' ? 'predefinida ' . h($defPhp) : '' ?></small></div></div></div>
        <a class="stat<?= $hot ? ' hot' : '' ?>" href="?p=recursos"><span class="tile t-warn"><?= ic('cpu') ?></span><div><div class="k">Disco e memória<?= $hot ? ' · atenção' : '' ?></div><div class="v"><?= $disk ?>% <small>disco · <?= $ram ?>% RAM</small></div><div class="meter"><i class="<?= $disk >= 90 ? 'hi' : '' ?>" style="width:<?= max(0, min(100, $disk)) ?>%"></i></div></div></a>
      </section>

      <div class="grid2">
        <section class="card">
          <div class="card-h"><div><h2>Sites</h2><p>Pedidos nas últimas 24 horas</p></div><a class="chip sm soft" href="?p=sites">Ver todos</a></div>
          <?php if (!$sites): ?>
            <div class="empty"><b>Ainda não há sites</b>Cria o primeiro; fica logo acessível numa porta própria.<br><button class="btn" type="button" data-open="dlg-site-new"><?= ic('plus') ?>Novo site</button></div>
          <?php else: ?>
          <div class="row-list bars">
            <?php foreach (array_slice($sorted, 0, 8) as $s): $n = (string)$s['name']; $port = (int)$s['port']; $on = !empty($s['enabled']); $rq = (int)($tr['per'][$n][0] ?? 0); ?>
              <div class="item">
                <div class="who"><span class="av <?= tone($n) ?>"><?= h(substr($n, 0, 1)) ?></span><div style="min-width:0"><div class="nm"><?= h($n) ?></div><div class="mu"><?php $mu = site_main_url($s); ?><?= $mu !== '' ? h(preg_replace('#^https?://|/$#', '', $mu)) . ' · ' : '' ?><span class="mono">:<?= $port ?></span> · PHP <?= h($s['php'] ?? '') ?></div></div></div>
                <div class="bar"><i style="width:<?= round($rq * 100 / $reqMax, 1) ?>%"></i></div>
                <b class="num"><?= h(fmt_int($rq)) ?></b>
                <span class="pill <?= $on ? 'p-ok' : 'p-off' ?>"><?= $on ? 'Ativo' : 'Desativado' ?></span>
                <?php if ($on): ?><a class="iconbtn" href="<?= h(site_main_url($s) !== '' ? site_main_url($s) : site_url($host, $port)) ?>" target="_blank" rel="noopener" title="Abrir" aria-label="Abrir <?= h($n) ?>"><?= ic('ext') ?></a><?php else: ?><span></span><?php endif; ?>
              </div>
            <?php endforeach; ?>
          </div>
          <?php endif; ?>
        </section>

        <section class="card">
          <div class="card-h"><div><h2>Serviços</h2><p>Estado atual</p></div><?php if ($svcDown > 0): ?><span class="pill p-err"><?= $svcDown ?> parado<?= $svcDown === 1 ? '' : 's' ?></span><?php else: ?><a class="chip sm soft" href="?p=servicos">Gerir</a><?php endif; ?></div>
          <div class="row-list">
            <?php if ($svcs && $svcDown === 0): ?>
              <div class="item"><span class="pill p-ok">Ativos</span><div class="grow nm">Todos os <?= count($svcs) ?> serviços a correr</div><a class="btn sm sec" href="?p=servicos">Ver serviços</a></div>
            <?php endif; ?>
            <?php foreach ($svcs as $s): $on = !empty($s['active']); if ($on) continue; ?>
              <div class="item">
                <span class="pill <?= $on ? 'p-ok' : 'p-err' ?>"><?= $on ? 'Ativo' : 'Parado' ?></span>
                <div class="grow nm"><?= h($s['name'] ?? '') ?></div>
                <?php if (($s['id'] ?? '') === 'nginx' || ($s['id'] ?? '') === 'mariadb' || !$on): ?>
                  <?= svc_actions($s, $bySite) ?>
                <?php else: ?>
                  <form method="post" style="margin:0"><?= act_fields('svc', ['svc' => (string)$s['id'], 'act' => 'reload']) ?><button class="btn sm sec" type="submit"><?= ic('reload') ?>Recarregar</button></form>
                <?php endif; ?>
              </div>
            <?php endforeach; ?>
            <?php if (!$svcs): ?><div class="empty">Sem informação dos serviços.</div><?php endif; ?>
          </div>
          <?php if ($svcs && $svcDown > 0 && $svcDown < count($svcs)): ?><div class="card-f mu" style="display:flex;align-items:center;gap:10px"><span class="grow">Os outros <?= count($svcs) - $svcDown ?> serviços estão a correr.</span><a class="btn sm sec" href="?p=servicos">Ver todos</a></div><?php endif; ?>
        </section>
      </div>

<?php elseif ($page === 'sites'): ?>
      <section class="card">
        <?php if (!$sites): ?>
          <div class="empty"><b>Ainda não há sites</b>Cria o primeiro; fica logo acessível numa porta própria.<br><button class="btn" type="button" data-open="dlg-site-new"><?= ic('plus') ?>Novo site</button></div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Site</th><th>Endereço</th><th>PHP</th><th>Limites</th><th>Estado</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php [$pgList, $pgN, $pgPages, $pgTot] = paginate($sites, 50); foreach ($pgList as $s):
                $n = (string)($s['name'] ?? ''); $port = (int)($s['port'] ?? 0); $on = !empty($s['enabled']); $L = site_limits($s);
                $url = site_url($host, $port); ?>
            <tr>
              <td class="first" data-label="Site"><div class="who"><span class="av <?= tone($n) ?>"><?= h(substr($n, 0, 1)) ?></span><div style="min-width:0"><div class="nm"><?= h($n) ?></div><div class="mu mono"><?= h($s['root'] ?? '') ?></div></div></div></td>
              <td data-label="Endereço">
                <?php $mu = site_main_url($s); $nd = count(array_filter(explode(' ', (string)($s['domains'] ?? '')))); ?>
                <?php if ($mu !== ''): ?>
                <?php if (($s['ssl'] ?? 'none') !== 'none' && empty($s['https_ok'])): ?><div style="margin-bottom:4px"><button type="button" class="pill p-warn" data-open="dlg-dom-<?= h($n) ?>" style="border:0;cursor:pointer" title="O certificado não foi emitido (o domínio já aponta para este servidor?)">Sem certificado · pedir novamente</button></div><?php endif; ?>
                <div class="links dom"><?= !empty($s['https_ok']) ? ic('lock', 'lock') : '' ?><?php if ($on): ?><a href="<?= h($mu) ?>" target="_blank" rel="noopener"><?= h(preg_replace('#^https?://|/$#', '', $mu)) ?><?= ic('ext') ?></a><?php else: ?><span><?= h(preg_replace('#^https?://|/$#', '', $mu)) ?></span><?php endif; ?><?= $nd > 1 ? ' <span class="mu">+' . ($nd - 1) . '</span>' : '' ?></div>
                <?php endif; ?>
                <div class="links"><span class="port">:<?= $port ?></span>
                <?php if ($on): ?> <a href="<?= h($url) ?>" target="_blank" rel="noopener"><?= h(preg_replace('#^http://|/$#', '', $url)) ?><?= ic('ext') ?></a><?php endif; ?></div>
              </td>
              <td data-label="PHP"><?= h($s['php'] ?? '') ?></td>
              <td data-label="Limites"><div class="lim"><span><b><?= (int)$L['memory'] ?></b> MB</span><span>upload <b><?= (int)$L['upload'] ?></b> MB</span><span><b><?= (int)$L['exec'] ?></b> s</span></div></td>
              <td data-label="Estado"><span class="pill <?= $on ? 'p-ok' : 'p-off' ?>"><?= $on ? 'Ativo' : 'Desativado' ?></span></td>
              <td class="act r">
                <details class="dd">
                  <summary class="iconbtn" aria-label="Ações de <?= h($n) ?>"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <?php if ($on): ?><a href="<?= h($url) ?>" target="_blank" rel="noopener"><?= ic('ext') ?>Abrir site</a><?php endif; ?>
                    <a href="?p=ficheiros&amp;site=<?= h(rawurlencode($n)) ?>"><?= ic('folder') ?>Ficheiros</a>
                    <a href="?p=cron&amp;site=<?= h(rawurlencode($n)) ?>"><?= ic('clock') ?>Tarefas agendadas</a>
                    <a href="?p=logs&amp;site=<?= h(rawurlencode($n)) ?>"><?= ic('logs') ?>Logs</a>
                    <button type="button" data-open="dlg-dom-<?= h($n) ?>"><?= ic('world') ?>Domínios e SSL</button>
                    <button type="button" data-open="dlg-perf-<?= h($n) ?>"><?= ic('pulse') ?>Desempenho<?= !empty($s['perf']['cache']) ? ' <span class="pill p-ok" style="margin-left:auto">Cache</span>' : '' ?></button>
                    <button type="button" data-open="dlg-ftp-<?= h($n) ?>"><?= ic('upload') ?>Acesso FTP/SFTP<?= !empty($s['ftp']) ? ' <span class="pill p-ok" style="margin-left:auto">Ativo</span>' : '' ?></button>
                    <button type="button" data-open="dlg-lim-<?= h($n) ?>"><?= ic('sliders') ?>Limites</button>
                    <button type="button" data-open="dlg-php-<?= h($n) ?>"><?= ic('code') ?>Mudar versão de PHP</button>
                    <form method="post"><?= act_fields('site_perm', ['site' => $n]) ?><button type="submit"><?= ic('lock') ?>Corrigir permissões</button></form>
                    <form method="post"><?= act_fields($on ? 'site_off' : 'site_on', ['site' => $n]) ?><button type="submit"><?= ic('toggle') ?><?= $on ? 'Desativar' : 'Ativar' ?></button></form>
                    <hr>
                    <button type="button" class="dan" data-open="dlg-del-<?= h($n) ?>"><?= ic('trash') ?>Apagar</button>
                  </div>
                </details>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php if ($pgPages > 1): ?><div class="card-f"><?= pager($pgN, $pgPages, $pgTot, 'pg', 'sites') ?></div><?php endif; ?>
        <?php endif; ?>
      </section>

<?php elseif ($page === 'recursos'):
    $live = live_stats();
    $tz = tz_off($live);
    $range = in_array(qget('r'), ['24h', '7d', '30d'], true) ? qget('r') : '24h';
    $H = hist_load($range);
    $sj = jload(MP_STATS . '/sites.json') ?? [];
    $sjs = is_array($sj['sites'] ?? null) ? $sj['sites'] : [];
    $ls = is_array($live['sites'] ?? null) ? $live['sites'] : [];
    $ncpu = max(1, (int)($live['cpus'] ?? ($sys['cpus'] ?? 1)));
    $mem = is_array($live['mem'] ?? null) ? $live['mem'] : [];
    $dsk = is_array($live['disk'] ?? null) ? $live['disk'] : [];
    $swp = is_array($live['swap'] ?? null) ? $live['swap'] : [];
    $load = is_array($live['load'] ?? null) ? $live['load'] : [0, 0, 0];
    $net = is_array($live['net'] ?? null) ? $live['net'] : [];
    $sCpu = [['CPU', 'var(--c1)', 1, 10], ['Memória', 'var(--c2)', 2, 10], ['Swap', 'var(--c3)', 3, 10]];
    $sNet = [['Receção', 'var(--c1)', 6, 1], ['Envio', 'var(--c2)', 7, 1]];
    $sLoad = [['Carga (1 min)', 'var(--c3)', 5, 100]];
    $pills = '<div class="pills">';
    foreach (['24h' => '24 h', '7d' => '7 dias', '30d' => '30 dias'] as $rk => $rl) $pills .= '<a class="' . ($rk === $range ? 'on' : '') . '" href="?p=recursos&amp;r=' . $rk . '">' . $rl . '</a>';
    $pills .= '</div>';
?>
      <?php if (!$live['fresh']): ?>
        <div class="card"><div class="empty"><b>O recolhedor de estatísticas não está a responder</b>No servidor: <span class="mono">systemctl status minipainel-stats</span></div></div>
      <?php endif; ?>
      <section class="stats stats5" data-live>
        <div class="stat"><span class="tile t-acc"><?= ic('cpu') ?></span><div><div class="k">CPU (<?= $ncpu ?> vCPU)</div><div class="v" data-l="cpu"><?= h(fmt_dec((float)($live['cpu'] ?? 0))) ?>%</div><div class="meter"><i data-lm="cpu" style="width:<?= min(100, (float)($live['cpu'] ?? 0)) ?>%"></i></div></div></div>
        <div class="stat"><span class="tile t-vio"><?= ic('server') ?></span><div><div class="k">Memória</div><div class="v"><span data-l="mem"><?= h(fmt_dec((float)($mem['pct'] ?? 0))) ?>%</span> <small data-l="mem-sub"><?= h(fmt_bytes((float)($mem['used'] ?? 0) * 1024) . ' / ' . fmt_bytes((float)($mem['total'] ?? 0) * 1024)) ?></small></div><div class="meter"><i data-lm="mem" style="width:<?= min(100, (float)($mem['pct'] ?? 0)) ?>%"></i></div></div></div>
        <div class="stat"><span class="tile t-warn"><?= ic('db') ?></span><div><div class="k">Disco /</div><div class="v"><span data-l="disk"><?= h(fmt_dec((float)($dsk['pct'] ?? 0))) ?>%</span> <small data-l="disk-sub"><?= h(fmt_bytes((float)($dsk['used'] ?? 0) * 1024) . ' / ' . fmt_bytes((float)($dsk['total'] ?? 0) * 1024)) ?></small></div><div class="meter"><i data-lm="disk" style="width:<?= min(100, (float)($dsk['pct'] ?? 0)) ?>%"></i></div></div></div>
        <div class="stat"><span class="tile t-blue"><?= ic('pulse') ?></span><div><div class="k">Carga</div><div class="v"><span data-l="load"><?= h(fmt_dec((float)($load[0] ?? 0), 2)) ?></span> <small data-l="load-sub">5 min <?= h(fmt_dec((float)($load[1] ?? 0), 2)) ?> · 15 min <?= h(fmt_dec((float)($load[2] ?? 0), 2)) ?></small></div><div class="mu" data-l="swap">Swap <?= h(fmt_dec((float)($swp['pct'] ?? 0))) ?>%</div></div></div>
        <div class="stat"><span class="tile t-acc"><?= ic('world') ?></span><div><div class="k">Rede</div><div class="v" data-l="net"><?= h(fmt_bps((float)($net['rx'] ?? 0) + (float)($net['tx'] ?? 0))) ?></div><div class="mu" data-l="net-sub">↓ <?= h(fmt_bps((float)($net['rx'] ?? 0))) ?> · ↑ <?= h(fmt_bps((float)($net['tx'] ?? 0))) ?></div></div></div>
      </section>

      <section class="card">
        <div class="card-h"><h2>CPU, memória e swap</h2><?= legend($sCpu) ?><?= $pills ?></div>
        <?= chart_html($H, $sCpu, 'pct', 100, null, $tz) ?>
      </section>

      <div class="grid2e">
        <section class="card">
          <div class="card-h"><h2>Rede</h2><?= legend($sNet) ?></div>
          <?= chart_html($H, $sNet, 'bps', null, null, $tz) ?>
        </section>
        <section class="card">
          <div class="card-h"><h2>Carga do sistema</h2><div class="legend"><span><i style="background:var(--c3)"></i>Carga (1 min)</span><span><i class="dash"></i><?= $ncpu ?> vCPU</span></div></div>
          <?= chart_html($H, $sLoad, 'load', null, (float)$ncpu, $tz) ?>
        </section>
      </div>

      <section class="card">
        <div class="card-h"><h2>Consumo por site</h2><p>CPU e RAM em tempo real; tráfego das últimas 24 horas.</p></div>
        <?php if (!$sites): ?>
          <div class="empty">Ainda não há sites.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Site</th><th class="r">CPU</th><th class="r">RAM</th><th class="r">Disco</th><th class="r">Pedidos (24 h)</th><th class="r">Tráfego (24 h)</th></tr></thead>
          <tbody>
          <?php foreach ($sites as $s): $n = (string)($s['name'] ?? ''); $L = $ls[$n] ?? []; $J = $sjs[$n] ?? []; ?>
            <tr>
              <td class="first" data-label="Site"><div class="who"><span class="av <?= tone($n) ?>"><?= h(substr($n, 0, 1)) ?></span><div><div class="nm"><?= h($n) ?></div><div class="mu"><span class="mono">:<?= (int)($s['port'] ?? 0) ?></span> · PHP <?= h($s['php'] ?? '') ?></div></div></div></td>
              <td class="r" data-label="CPU" data-ls="<?= h($n) ?>:cpu"><?= h(fmt_dec((float)($L['cpu'] ?? 0))) ?>%</td>
              <td class="r" data-label="RAM" data-ls="<?= h($n) ?>:rss"><?= h(fmt_bytes((float)($L['rss'] ?? 0) * 1024)) ?></td>
              <td class="r" data-label="Disco"><?= isset($J['disk']) && (int)($sj['disk_ts'] ?? 0) > 0 ? h(fmt_bytes((float)$J['disk'])) : '<span class="mu">a medir…</span>' ?></td>
              <td class="r" data-label="Pedidos (24 h)"><?= h(fmt_int((float)($J['req24'] ?? 0))) ?></td>
              <td class="r" data-label="Tráfego (24 h)"><?= h(fmt_bytes((float)($J['bytes24'] ?? 0))) ?></td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
        <div class="card-f mu">CPU em percentagem da capacidade total do servidor. A RAM é aproximada (inclui memória partilhada entre processos). O disco de cada site é medido de hora a hora; as bases de dados não estão incluídas.</div>
      </section>

<?php elseif ($page === 'ficheiros'):
    $names = [];
    foreach ($sites as $s) { $n = (string)($s['name'] ?? ''); if (valid_site($n)) $names[] = $n; }
    $mailOnFm = !empty($state['mail']['enabled']);
    $fmSite = in_array(qget('site'), $names, true) ? qget('site') : (($mailOnFm && qget('site') === '_email') ? '_email' : '');
    $fmArea = qget('area') === 'sites' ? 'sites' : '';
    $nDom = is_array($state['mail']['domains'] ?? null) ? count($state['mail']['domains']) : 0;
?>
      <?php if ($fmSite === ''): ?>
      <section class="card">
        <div class="card-h"><nav class="crumbs fm-pre" aria-label="Caminho"><a href="?p=ficheiros"><?= ic('home') ?>Ficheiros</a><?php if ($fmArea === 'sites'): ?><span>›</span><a href="?p=ficheiros&amp;area=sites">Sites</a><?php endif; ?></nav></div>
        <table class="list cards fm-root">
          <thead><tr><th>Nome</th><th>Conteúdo</th><th>Localização</th></tr></thead>
          <tbody>
          <?php if ($fmArea === ''): ?>
            <tr><td class="first" data-label="Nome"><a class="who" href="?p=ficheiros&amp;area=sites"><span class="av t-blue"><?= ic('folder') ?></span><span class="nm">Sites</span></a></td><td data-label="Conteúdo"><?= count($names) ?> site<?= count($names) === 1 ? '' : 's' ?></td><td class="mono mu" data-label="Localização">/srv/www</td></tr>
            <?php if ($mailOnFm): ?>
            <tr><td class="first" data-label="Nome"><a class="who" href="?p=ficheiros&amp;site=_email"><span class="av t-vio"><?= ic('mail') ?></span><span class="nm">Email</span></a></td><td data-label="Conteúdo"><?= $nDom ?> domínio<?= $nDom === 1 ? '' : 's' ?></td><td class="mono mu" data-label="Localização">/var/mail/vhosts</td></tr>
            <?php else: ?>
            <tr><td class="first" data-label="Nome"><span class="who"><span class="av t-vio"><?= ic('mail') ?></span><span class="nm mu">Email</span></span></td><td class="mu" data-label="Conteúdo">O email não está ativo · <a href="?p=email">Ativar</a></td><td class="mono mu" data-label="Localização">/var/mail/vhosts</td></tr>
            <?php endif; ?>
          <?php else: ?>
            <?php if (!$names): ?><tr><td colspan="3"><div class="empty"><b>Ainda não há sites</b><button class="btn" type="button" data-open="dlg-site-new"><?= ic('plus') ?>Novo site</button></div></td></tr><?php endif; ?>
            <?php foreach ($sites as $s): $n = (string)($s['name'] ?? ''); if (!valid_site($n)) continue; $mu = site_main_url($s); ?>
            <tr><td class="first" data-label="Nome"><a class="who" href="?p=ficheiros&amp;site=<?= h(rawurlencode($n)) ?>"><span class="av <?= tone($n) ?>"><?= ic('folder') ?></span><span class="nm"><?= h($n) ?></span></a></td><td data-label="Conteúdo" class="mu"><?= $mu !== '' ? h(preg_replace('#^https?://|/$#', '', $mu)) . ' · ' : '' ?>porta <?= (int)$s['port'] ?></td><td class="mono mu" data-label="Localização">/srv/www/<?= h($n) ?></td></tr>
            <?php endforeach; ?>
          <?php endif; ?>
          </tbody>
        </table>
        <div class="card-f mu">Cada pasta é aberta com o utilizador do respetivo site (ou do email), por isso os ficheiros criados ficam sempre com o dono certo. Os ficheiros do sistema não são acessíveis pelo painel.</div>
      </section>
      <?php else: ?>
      <section class="card fm" id="fm" data-site="<?= h($fmSite) ?>" data-label="<?= h($fmSite === '_email' ? 'Email' : $fmSite) ?>" data-noedit="<?= $fmSite === '_email' ? '1' : '0' ?>" data-dir="<?= h(qget('dir')) ?>">
        <div class="fm-bar">
          <nav class="crumbs fm-pre" aria-label="Raiz"><a href="?p=ficheiros"><?= ic('home') ?>Ficheiros</a><span>›</span><?php if ($fmSite !== '_email'): ?><a href="?p=ficheiros&amp;area=sites">Sites</a><span>›</span><?php endif; ?></nav>
          <nav class="crumbs" id="fm-crumbs" aria-label="Caminho"></nav>
          <div class="fm-tools">
            <button class="btn sm sec" type="button" data-fm="mkdir"><?= ic('folderplus') ?>Nova pasta</button>
            <?php if ($fmSite !== '_email'): ?><button class="btn sm sec" type="button" data-fm="newfile"><?= ic('file') ?>Novo ficheiro</button><?php endif; ?>
            <label class="btn sm sec"><?= ic('upload') ?>Enviar pasta<input type="file" id="fm-updir" webkitdirectory multiple hidden></label>
            <label class="btn sm"><?= ic('upload') ?>Enviar ficheiros<input type="file" id="fm-upfiles" multiple hidden></label>
          </div>
        </div>
        <div class="fm-selbar" id="fm-selbar" hidden>
          <span id="fm-selcount"></span><span class="grow"></span>
          <button class="btn sm sec" type="button" data-fm="move"><?= ic('move') ?>Mover</button>
          <button class="btn sm sec" type="button" data-fm="zip"><?= ic('zip') ?>Compactar</button>
          <button class="btn sm sec" type="button" data-fm="chmod"><?= ic('lock') ?>Permissões</button>
          <button class="btn sm dan" type="button" data-fm="delete"><?= ic('trash') ?>Apagar</button>
          <button class="btn sm sec" type="button" data-fm="clear">Limpar seleção</button>
        </div>
        <div class="fm-drop" id="fm-drop">
          <table class="list cards fm-list">
            <thead><tr><th><label class="fm-ck"><input type="checkbox" id="fm-all" aria-label="Selecionar tudo"></label> Nome</th><th class="r">Tamanho</th><th>Modificado</th><th>Permissões</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
            <tbody id="fm-rows"><tr><td colspan="5" class="empty">A carregar…</td></tr></tbody>
          </table>
          <div class="fm-hint">Larga aqui para enviar para esta pasta</div>
        </div>
        <div class="card-f mu" id="fm-foot"><?= $fmSite === '_email' ? 'Área Email: uma pasta por domínio e por caixa (formato Maildir). Podes ver, descarregar e apagar; as mensagens não se editam aqui para não danificar os índices do Dovecot.' : 'Arrasta ficheiros ou pastas para a lista para os enviar. Os envios são feitos por partes e retomam se a ligação falhar.' ?></div>
      </section>
      <div class="fm-menu" id="fm-menu" hidden></div>
      <div class="ups" id="fm-ups" hidden>
        <div class="ups-h"><b>Envios</b><span id="fm-ups-sum"></span><button class="iconbtn" type="button" id="fm-ups-close" aria-label="Fechar"><?= ic('x') ?></button></div>
        <div class="ups-l" id="fm-ups-list"></div>
      </div>
      <dialog id="fm-dlg">
        <form method="dialog">
          <div class="dlg-h"><h3 id="fm-dlg-t"></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
          <div class="dlg-b"><div id="fm-dlg-msg" class="mu"></div><input class="in" id="fm-dlg-in" autocomplete="off"></div>
          <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" id="fm-dlg-ok" value="ok">OK</button></div>
        </form>
      </dialog>
      <dialog class="drawer fm-ed" id="fm-ed" data-keep>
        <div class="dlg-h"><div style="min-width:0"><h3>Editar ficheiro</h3><p class="mono" id="fm-ed-t"></p></div><button class="iconbtn" type="button" id="fm-ed-x" aria-label="Fechar"><?= ic('x') ?></button></div>
        <textarea id="fm-ed-ta" spellcheck="false" autocapitalize="off" autocomplete="off" aria-label="Conteúdo do ficheiro"></textarea>
        <div class="dlg-f"><span class="mu" id="fm-ed-st"></span><button class="btn sec" type="button" id="fm-ed-close">Fechar</button><button class="btn" type="button" id="fm-ed-save">Gravar (Ctrl+S)</button></div>
      </dialog>
      <?php endif; ?>

<?php elseif ($page === 'bd'): ?>
      <?php $pg = is_array($state['perf'] ?? null) ? $state['perf'] : []; $slow = jload(MP_STATS . '/db-slow.json') ?? ['rows' => []]; ?>
      <?php $btab = in_array(qget('t'), ['lista', 'desempenho', 'pma'], true) ? qget('t') : 'lista'; ?>
      <nav class="tabs" aria-label="Secções">
        <a class="chip<?= $btab === 'lista' ? ' prim' : '' ?>" href="?p=bd">Bases de dados <span class="sn-cnt"><?= count($dbs) ?></span></a>
        <a class="chip<?= $btab === 'desempenho' ? ' prim' : '' ?>" href="?p=bd&amp;t=desempenho">Desempenho</a>
        <a class="chip<?= $btab === 'pma' ? ' prim' : '' ?>" href="?p=bd&amp;t=pma">phpMyAdmin</a>
      </nav>
      <?php if ($btab === 'lista'): ?>
      <section class="card">
        <?php if (!$dbs): ?>
          <div class="empty"><b>Ainda não há bases de dados</b>Cada base de dados é criada com um utilizador próprio.<br><button class="btn" type="button" data-open="dlg-db-new"><?= ic('plus') ?>Nova base de dados</button></div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Base de dados</th><th>Utilizador</th><th>Site</th><th class="r">Tamanho</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php [$pgList, $pgN, $pgPages, $pgTot] = paginate($dbs, 50); foreach ($pgList as $d): $n = (string)($d['name'] ?? ''); ?>
            <tr>
              <td class="first" data-label="Base de dados"><div class="who"><span class="av t-blue"><?= ic('db') ?></span><div class="nm mono"><?= h($n) ?></div></div></td>
              <td class="mono" data-label="Utilizador"><?= h($n) ?>@localhost</td>
              <td data-label="Site"><?= ($d['site'] ?? '') !== '' ? '<span class="pill p-me">' . h($d['site']) . '</span>' : '<span class="mu">—</span>' ?></td>
              <td class="r" data-label="Tamanho"><?= h(number_format((float)($d['size_mb'] ?? 0), 2, ',', ' ')) ?> MB</td>
              <td class="act r">
                <details class="dd">
                  <summary class="iconbtn" aria-label="Ações de <?= h($n) ?>"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <?php if ($pmaOn): ?><a href="/phpmyadmin/index.php?route=/database/structure&amp;db=<?= h(rawurlencode($n)) ?>" target="_blank" rel="noopener"><?= ic('table') ?>Abrir no phpMyAdmin</a><?php endif; ?>
                    <button type="button" data-open="dlg-dblink-<?= h($n) ?>"><?= ic('world') ?>Associar a um site</button>
                    <button type="button" data-open="dlg-dbpw-<?= h($n) ?>"><?= ic('key') ?>Mudar password</button>
                    <hr>
                    <button type="button" class="dan" data-open="dlg-dbdel-<?= h($n) ?>"><?= ic('trash') ?>Apagar</button>
                  </div>
                </details>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php if ($pgPages > 1): ?><div class="card-f"><?= pager($pgN, $pgPages, $pgTot, 'pg', 'bases de dados') ?></div><?php endif; ?>
        <?php endif; ?>
      </section>
      <?php elseif ($btab === 'desempenho'): ?>
      <div class="grid2e" style="align-items:stretch">
      <section class="card">
        <div class="card-h"><div><h2>Desempenho do MariaDB</h2><p>A memória para dados evita leituras ao disco. Por omissão o MariaDB usa só 128 MB.</p></div></div>
        <form method="post" class="card-b" data-confirm="Aplicar? O MariaDB é reiniciado (os sites ficam alguns segundos sem base de dados). Se não arrancar, a configuração anterior é reposta sozinha.">
          <?= act_fields('db_tune') ?>
          <div class="fgrid">
            <label class="fld">Memória para dados (MB)<input class="in" name="bp" value="<?= h((string)($pg['db_bp'] ?? 'auto')) ?>" placeholder="auto"><small>auto = <?= (int)($pg['db_bp_auto'] ?? 128) ?> MB (servidor com <?= number_format((int)($pg['ram_mb'] ?? 0) / 1024, 1, ',', '') ?> GB de RAM)</small></label>
            <label class="fld">Registar consultas lentas<select class="in" name="slow"><option value="on"<?= !empty($pg['db_slow']) ? ' selected' : '' ?>>Sim</option><option value="off"<?= empty($pg['db_slow']) ? ' selected' : '' ?>>Não</option></select></label>
            <label class="fld">Consulta lenta a partir de (s)<input class="in" name="slow_t" inputmode="numeric" value="<?= (int)($pg['db_slow_t'] ?? 2) ?>"></label>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Aplicar</button></div>
        </form>
      </section>
      <section class="card">
        <div class="card-h"><div><h2>Consultas mais lentas</h2><p>Agrupadas por forma (os valores trocados por N), ordenadas pelo tempo total. Atualizado de hora a hora<?= !empty($slow['ts']) ? ' · última vez às ' . h(gmdate('H:i', (int)$slow['ts'] + tz_off(live_stats()))) : '' ?>.</p></div>
          <form method="post"><?= act_fields('db_slow_report') ?><button class="btn sm sec" type="submit">Atualizar</button></form></div>
        <?php if (empty($slow['rows'])): ?><div class="empty">Sem consultas lentas registadas<?= empty($pg['db_slow']) ? ' (o registo está desligado)' : '' ?>.</div>
        <?php else: ?><div class="row-list"><?php foreach (array_slice($slow['rows'], 0, 10) as $q): ?>
          <div class="item"><div class="grow"><div class="mono pr-cmd" title="<?= h((string)$q['query']) ?>" style="max-width:100%"><?= h((string)$q['query']) ?></div>
            <div class="mu"><?= (int)$q['count'] ?>× · média <?= h(str_replace('.', ',', (string)$q['avg'])) ?> s · total <?= h(str_replace('.', ',', (string)$q['total'])) ?> s · <?= h((string)$q['user']) ?></div></div></div>
        <?php endforeach; ?></div><?php endif; ?>
      </section>
      </div>
      <?php else: ?>
      <section class="card">
        <div class="row-list">
          <div class="item">
            <span class="av t-acc"><?= ic('table') ?></span>
            <div class="grow"><div class="nm">phpMyAdmin</div><div class="mu"><?= $pmaOn ? 'Versão ' . h($pma['version'] ?? '') . '. Só abre com sessão iniciada neste painel; o login é feito com um utilizador da base de dados.' : 'Não está instalado. Instala a versão oficial mais recente.' ?></div></div>
            <div class="svc-acts">
              <?php if ($pmaOn): ?><a class="btn sm" href="/phpmyadmin/" target="_blank" rel="noopener"><?= ic('ext') ?>Abrir phpMyAdmin</a><?php endif; ?>
              <form method="post"><?= act_fields('pma_update') ?><button class="btn sm sec" type="submit"><?= ic('reload') ?><?= $pmaOn ? 'Procurar atualização' : 'Instalar' ?></button></form>
            </div>
          </div>
          <div class="item">
            <span class="av t-warn"><?= ic('shield') ?></span>
            <div class="grow"><div class="nm mono"><?= h($dbAdmin['user'] ?? 'mpadmin') ?>@localhost</div><div class="mu">Conta de administração com acesso a todas as bases de dados. Só funciona a partir do próprio servidor, por exemplo no phpMyAdmin.</div></div>
            <div class="svc-acts">
              <form method="post" data-confirm="<?= !empty($dbAdmin['exists']) ? h('Gerar uma nova password para a conta de administração? A password atual deixa de funcionar.') : '' ?>"><?= act_fields('db_admin_pw') ?><button class="btn sm sec" type="submit"><?= ic('key') ?><?= !empty($dbAdmin['exists']) ? 'Gerar nova password' : 'Criar conta' ?></button></form>
            </div>
          </div>
        </div>
      </section>
      <?php endif; ?>

<?php elseif ($page === 'php'):
    $selV = qget('v') !== '' ? qget('v') : $defPhp;
    $sel = null;
    foreach ($phps as $p) { if ((string)($p['version'] ?? '') === $selV) $sel = $p; }
    if ($sel === null && $phps) $sel = $phps[0];
    $sv = $sel !== null ? (string)($sel['version'] ?? '') : '';
    $ptab = in_array(qget('t'), ['versoes', 'extensoes', 'opcache'], true) ? qget('t') : 'versoes';
?>
      <nav class="tabs" aria-label="Secções">
        <a class="chip<?= $ptab === 'versoes' ? ' prim' : '' ?>" href="?p=php">Versões <span class="sn-cnt"><?= count($phps) ?></span></a>
        <a class="chip<?= $ptab === 'extensoes' ? ' prim' : '' ?>" href="?p=php&amp;t=extensoes<?= $sv !== '' ? '&amp;v=' . h($sv) : '' ?>">Extensões</a>
        <a class="chip<?= $ptab === 'opcache' ? ' prim' : '' ?>" href="?p=php&amp;t=opcache">OPcache</a>
      </nav>
      <?php if ($ptab === 'versoes'): ?>
      <section class="card">
        <div class="card-h"><h2>Versões instaladas</h2><p>Para acrescentar versões, volta a correr o instalador com --php.</p></div>
        <?php if (!$phps): ?>
          <div class="empty">Sem informação sobre versões de PHP.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Versão</th><th>Serviço</th><th class="r">Sites</th><th class="r">Extensões opcionais</th><th>Predefinida</th></tr></thead>
          <tbody>
          <?php foreach ($phps as $p): $v = (string)($p['version'] ?? '');
                $ni = count(array_filter(is_array($p['extensions'] ?? null) ? $p['extensions'] : [], function ($e) { return !empty($e['installed']); })); ?>
            <tr>
              <td class="first" data-label="Versão"><div class="who"><span class="av t-vio"><?= ic('code') ?></span><div><a class="nm" href="?p=php&amp;t=extensoes&amp;v=<?= h(rawurlencode($v)) ?>">PHP <?= h($v) ?></a><?php $sup = php_support($v); ?><div><span class="pill <?= $sup[1] ?>"><?= h($sup[0]) ?></span></div></div></div></td>
              <td data-label="Serviço"><span class="pill <?= !empty($p['active']) ? 'p-ok' : 'p-err' ?>"><?= !empty($p['active']) ? 'A correr' : 'Parado' ?></span></td>
              <td class="r" data-label="Sites"><?= (int)($bySite[$v] ?? 0) ?></td>
              <td class="r" data-label="Extensões opcionais"><?= $ni ?></td>
              <td data-label="Predefinida"><?= $v === $defPhp ? 'Sim' : 'Não' ?></td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
      </section>
      <?php elseif ($ptab === 'extensoes'): ?>
      <?php if ($sel !== null):
            $exts = is_array($sel['extensions'] ?? null) ? $sel['extensions'] : [];
            $mods = is_array($sel['modules'] ?? null) ? $sel['modules'] : []; ?>
      <section class="card">
        <div class="card-h">
          <h2>Extensões do PHP <?= h($sv) ?></h2>
          <div class="pills"><?php foreach ($phps as $p): $v = (string)($p['version'] ?? ''); ?><a class="<?= $v === $sv ? 'on' : '' ?>" href="?p=php&amp;t=extensoes&amp;v=<?= h(rawurlencode($v)) ?>">PHP <?= h($v) ?></a><?php endforeach; ?></div>
        </div>
        <?php $ns = (int)($bySite[$sv] ?? 0); ?>
        <p class="lead">Aplicam-se a todos os sites com PHP <?= h($sv) ?> (<?= $ns ?> site<?= $ns === 1 ? '' : 's' ?>). Instalar ou remover pode demorar alguns minutos.</p>
        <?php if (!$exts): ?>
          <div class="empty">Sem informação sobre extensões.</div>
        <?php else: ?>
        <div class="exts">
          <?php foreach ($exts as $e): $x = (string)($e['name'] ?? ''); $inst = !empty($e['installed']); ?>
            <div class="ext<?= $inst ? ' on' : '' ?>">
              <div class="d"><b><?= h($x) ?></b><span><?= h($e['desc'] ?? '') ?></span></div>
              <form method="post"<?= $inst ? ' data-confirm="' . h('Remover a extensão ' . $x . ' do PHP ' . $sv . '?') . '"' : '' ?>>
                <?= act_fields($inst ? 'ext_del' : 'ext_add', ['php' => $sv, 'ext' => $x]) ?>
                <?php if ($inst): ?><span class="pill p-ok">Instalada</span><?php endif; ?>
                <button class="btn sm sec" type="submit"><?= $inst ? 'Remover' : 'Instalar' ?></button>
              </form>
            </div>
          <?php endforeach; ?>
        </div>
        <?php endif; ?>
        <?php if ($mods): ?>
          <div class="card-f"><div class="mu" style="margin-bottom:8px">Módulos carregados (<?= count($mods) ?>)</div><div class="chips"><?php foreach ($mods as $m): ?><span class="chip"><?= h($m) ?></span><?php endforeach; ?></div></div>
        <?php endif; ?>
      </section>
      <?php endif; ?>
      <?php else: ?>
      <?php $pg = is_array($state['perf'] ?? null) ? $state['perf'] : []; ?>
      <section class="card">
        <div class="card-h"><div><h2>OPcache</h2><p>Guarda o código PHP já compilado em memória, em todas as versões. Depois de atualizar um site por FTP, as alterações aparecem no máximo ao fim do tempo de verificação (ou de imediato com "Limpar OPcache").</p></div>
          <form method="post"><?= act_fields('opcache_reset') ?><button class="btn sm sec" type="submit">Limpar OPcache</button></form></div>
        <form method="post" class="card-b" style="display:flex;gap:14px;align-items:flex-end;flex-wrap:wrap">
          <?= act_fields('opcache_settings') ?>
          <label class="fld" style="min-width:220px">Memória<select class="in" name="mem"><option value="auto"<?= ($pg['opc_mem'] ?? 'auto') === 'auto' ? ' selected' : '' ?>>Automática (<?= (int)($pg['opc_mem_auto'] ?? 128) ?> MB)</option><?php foreach ([128, 256, 512, 1024] as $mb): ?><option value="<?= $mb ?>"<?= (string)($pg['opc_mem'] ?? '') === (string)$mb ? ' selected' : '' ?>><?= $mb ?> MB</option><?php endforeach; ?></select></label>
          <label class="fld" style="min-width:260px">Verificar alterações aos ficheiros<select class="in" name="reval"><?php foreach (['0' => 'Em cada pedido (mais lento)', '2' => 'A cada 2 segundos', '60' => 'A cada minuto (recomendado)', '300' => 'A cada 5 minutos'] as $k => $l): ?><option value="<?= $k ?>"<?= (int)($pg['opc_reval'] ?? 60) === (int)$k ? ' selected' : '' ?>><?= $l ?></option><?php endforeach; ?></select></label>
          <button class="btn" type="submit">Guardar</button>
        </form>
      </section>
      <?php endif; ?>

<?php elseif ($page === 'ligacoes'):
    $cj = jload(MP_STATS . '/conns.json') ?? [];
    $fw = jload(MP_STATS . '/fw.json') ?? [];
    $fwAuto = is_array($fw['auto'] ?? null) ? $fw['auto'] : ['on' => false, 'limit' => 150, 'duration' => 3600];
    $fwBlocks = array_values(array_filter(is_array($fw['blocks'] ?? null) ? $fw['blocks'] : [], function ($b) { return (int)($b['exp'] ?? 0) === 0 || (int)$b['exp'] > time(); }));
    $fwAllow = is_array($fw['allow'] ?? null) ? $fw['allow'] : [];
    $portLabels = [];
    foreach ($sites as $s) $portLabels[(string)(int)($s['port'] ?? 0)] = (string)($s['name'] ?? '');
    $portLabels[(string)(int)($sys['panel_port'] ?? 2443)] = 'Painel';
    $portLabels += ['22' => 'SSH', '3306' => 'MariaDB', '80' => 'HTTP', '443' => 'HTTPS', '25' => 'SMTP', '587' => 'SMTP', '465' => 'SMTPS', '993' => 'IMAPS', '995' => 'POP3S', '21' => 'FTP', '53' => 'DNS', '2096' => 'Webmail'];
    $durs = ['600s' => '10 minutos', '1h' => '1 hora', '24h' => '24 horas', '7d' => '7 dias'];
    $curDur = (int)($fwAuto['duration'] ?? 3600);
    $tzl = tz_off(live_stats());
    $geo = is_array($state['geo'] ?? null) ? $state['geo'] : ['block' => [], 'home' => 'PT', 'countries' => [], 'updated' => 0, 'ovl' => ['on' => true, 'capacity' => 0, 'start' => 80, 'stop' => 60, 'max' => 'auto']];
    $ovl = jload(MP_STATS . '/overload.json') ?? ['active' => false];
    $ltab = in_array(qget('t'), ['ativas', 'paises', 'bloqueios', 'protecao'], true) ? qget('t') : 'ativas';
    $allCc = array_values(array_filter((array)($geo['countries'] ?? []), function ($c) { return preg_match('/^[A-Z]{2}$/', $c); }));
    usort($allCc, function ($a, $b) { return strcoll(cc_name($a), cc_name($b)); });
?>
      <?php if (empty($fw['nft'])): ?>
        <div class="card"><div class="empty"><b>A firewall do painel não está ativa</b>No servidor: <span class="mono">mpanel fw-restore</span> (requer o pacote nftables).</div></div>
      <?php endif; ?>
      <?php if (!empty($ovl['active'])): ?>
        <div class="card ovl-on"><div class="card-b"><b><?= ic('ban') ?> Modo de proteção ativo</b> desde <?= h(gmdate('H:i', (int)($ovl['since'] ?? time()) + $tzl)) ?>: <?= (int)($ovl['total'] ?? 0) ?> ligações para uma capacidade de <?= (int)($ovl['capacity'] ?? 0) ?>. Só são aceites ligações novas de <?= cc_flag((string)($ovl['home'] ?? 'PT')) ?> <?= h(cc_name((string)($ovl['home'] ?? 'PT'))) ?>, da rede local e dos IPs de confiança.</div></div>
      <?php endif; ?>
      <nav class="tabs" aria-label="Secções">
        <?php foreach (['ativas' => 'Ligações ativas', 'paises' => 'Países', 'bloqueios' => 'Bloqueios (' . count($fwBlocks) . ')', 'protecao' => 'Proteção e limites'] as $tk => $tl): ?>
          <a class="chip<?= $ltab === $tk ? ' prim' : '' ?>" href="?p=ligacoes&amp;t=<?= $tk ?>"><?= h($tl) ?></a>
        <?php endforeach; ?>
      </nav>

  <?php if ($ltab === 'ativas' || $ltab === 'paises'): ?>
      <section class="stats" id="cn-stats">
        <div class="stat"><span class="tile t-acc"><?= ic('pulse') ?></span><div><div class="k">Ligações abertas</div><div class="v"><span data-c="total"><?= (int)($cj['total'] ?? 0) ?></span> <small>/ <?= (int)($geo['ovl']['capacity'] ?? 0) ?></small></div></div></div>
        <div class="stat"><span class="tile t-blue"><?= ic('world') ?></span><div><div class="k">IPs distintos</div><div class="v" data-c="distinct"><?= (int)($cj['distinct'] ?? 0) ?></div></div></div>
        <div class="stat"><span class="tile t-warn"><?= ic('reload') ?></span><div><div class="k">Em espera (SYN)</div><div class="v" data-c="syn"><?= (int)($cj['syn'] ?? 0) ?></div></div></div>
        <div class="stat"><span class="tile <?= !empty($ovl['active']) ? 't-warn' : 't-vio' ?>"><?= ic('ban') ?></span><div><div class="k">Proteção</div><div class="v" style="font-size:17px"><?= !empty($ovl['active']) ? 'Ativa' : (!empty($geo['ovl']['on']) ? 'Em vigilância' : 'Desligada') ?></div></div></div>
      </section>
  <?php endif; ?>

  <?php if ($ltab === 'ativas'): ?>
      <section class="card" id="cn" data-mode="ip" data-me="<?= h($myIp) ?>" data-limit="<?= (int)$fwAuto['limit'] ?>" data-auto="<?= !empty($fwAuto['on']) ? 1 : 0 ?>"
        data-labels="<?= h((string)json_encode($portLabels)) ?>" data-allow="<?= h((string)json_encode(array_values($fwAllow))) ?>">
        <div class="card-h">
          <div><h2>Ligações por IP</h2><p>Atualiza a cada 5 segundos. Só ligações a serviços deste servidor.</p></div>
          <input class="in cn-search" id="cn-q" type="search" placeholder="Procurar IP ou país…" aria-label="Procurar" autocomplete="off">
        </div>
        <table class="list cards">
          <thead><tr><th>IP de origem</th><th>País</th><th class="r">Ligações</th><th>Destino</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody id="cn-rows"><tr><td colspan="5" class="empty">A carregar…</td></tr></tbody>
        </table>
        <div class="card-f" style="display:flex;align-items:center;gap:12px;flex-wrap:wrap"><span class="mu" id="cn-foot" style="flex:1"></span><nav class="pager" id="cn-pager"></nav></div>
      </section>

  <?php elseif ($ltab === 'paises'): ?>
      <div class="grid2e">
      <section class="card" id="cn" data-mode="cc" data-home="<?= h((string)$geo['home']) ?>" data-blocked="<?= h((string)json_encode(array_values((array)$geo['block']))) ?>">
        <div class="card-h"><div><h2>Origem das ligações agora</h2><p>Por país, a partir dos IPs com ligações abertas. Atualiza a cada 5 segundos.</p></div></div>
        <div id="cc-rows" class="row-list"><div class="empty">A carregar…</div></div>
      </section>
      <section class="card">
        <div class="card-h"><div><h2>Países bloqueados</h2><p>Ligações novas destes países são recusadas em todas as portas. As respostas às ligações feitas pelo próprio servidor continuam a passar.</p></div></div>
        <?php if (!$geo['block']): ?><div class="empty">Nenhum país bloqueado.</div>
        <?php else: ?><div class="row-list">
          <?php foreach ((array)$geo['block'] as $cc): ?><div class="item"><span class="cc-flag"><?= cc_flag((string)$cc) ?></span><div class="grow"><div class="nm"><?= h(cc_name((string)$cc)) ?></div><div class="mu mono"><?= h($cc) ?></div></div>
            <form method="post"><?= act_fields('geo_block', ['op' => 'del', 'cc' => (string)$cc]) ?><button class="btn sm sec" type="submit">Desbloquear</button></form></div><?php endforeach; ?>
        </div><?php endif; ?>
        <form method="post" class="card-b" style="display:flex;gap:10px;align-items:flex-end;flex-wrap:wrap" data-confirm="Bloquear este país? Visitantes, robôs de pesquisa e serviços desse país deixam de chegar aos sites e ao email.">
          <?= act_fields('geo_block', ['op' => 'add']) ?>
          <label class="fld" style="flex:1;min-width:220px">País<select class="in" name="cc" required><option value="">— escolher —</option>
            <?php foreach ($allCc as $cc): if ($cc === ($geo['home'] ?? 'PT') || in_array($cc, (array)$geo['block'], true)) continue; ?><option value="<?= h($cc) ?>"><?= cc_flag($cc) ?> <?= h(cc_name($cc)) ?></option><?php endforeach; ?>
          </select></label>
          <button class="btn dan" type="submit">Bloquear país</button>
        </form>
        <div class="card-f"><div class="warnbox">Cuidado: bloquear países pode impedir a renovação de certificados (o Let's Encrypt valida a partir de vários países, incluindo os EUA), os robôs de pesquisa (Google, Bing) e as notificações de pagamentos (MB Way, Stripe, PayPal…) vindas desses países.</div>
          <p class="mu" style="margin:10px 0 0;font-size:12px">Geolocalização por <a href="https://db-ip.com" target="_blank" rel="noopener">DB-IP</a> (CC BY 4.0) · base de <?= !empty($geo['updated']) ? h(gmdate('m/Y', (int)$geo['updated'])) : '—' ?>, atualizada todos os meses<?php if (empty($geo['updated'])): ?> · <form method="post" style="display:inline"><?= act_fields('geoip_update') ?><button class="lnk" type="submit" style="display:inline">descarregar agora</button></form><?php endif; ?></p></div>
      </section>
      </div>

  <?php elseif ($ltab === 'bloqueios'): [$bl, $bpg, $bpages, $btot] = paginate($fwBlocks, 50); ?>
      <section class="card">
        <div class="card-h"><div><h2>IPs e gamas bloqueados</h2><p>Bloqueados em todas as portas, incluindo SSH. Aceita um IP (185.220.101.47) ou uma gama (45.148.10.0/24).</p></div><button class="chip sm soft" type="button" data-open="dlg-block">Bloquear IP ou gama</button></div>
        <?php if (!$fwBlocks): ?>
          <div class="empty">Nenhum IP bloqueado.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>IP / gama</th><th>País</th><th>Origem</th><th>Motivo</th><th>Expira</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($bl as $b): $exp = (int)($b['exp'] ?? 0); $left = $exp - time(); $bip = (string)($b['ip'] ?? ''); $bcc = geo_cc(explode('/', $bip)[0]); ?>
            <tr>
              <td class="first" data-label="IP"><div class="nm mono"><?= h($bip) ?></div></td>
              <td data-label="País"><span class="cc-flag"><?= cc_flag($bcc) ?></span> <?= h(cc_name($bcc)) ?></td>
              <td data-label="Origem"><span class="pill <?= ($b['by'] ?? '') === 'auto' ? 'p-err' : 'p-off' ?>"><?= ($b['by'] ?? '') === 'auto' ? 'Automático' : 'Manual' ?></span></td>
              <td data-label="Motivo" class="mu"><?= h(($b['reason'] ?? '') !== '' ? $b['reason'] : '—') ?></td>
              <td data-label="Expira"><?= $exp === 0 ? 'Permanente' : 'em ' . h($left >= 86400 ? round($left / 86400) . ' d' : ($left >= 3600 ? round($left / 3600) . ' h' : max(1, (int)round($left / 60)) . ' min')) ?></td>
              <td class="act r"><form method="post" style="margin:0"><?= act_fields('fw_unblock', ['ip' => $bip]) ?><button class="btn sm sec" type="submit">Desbloquear</button></form></td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <div class="card-f"><?= pager($bpg, $bpages, $btot, 'pg', 'bloqueios') ?></div>
        <?php endif; ?>
      </section>
      <section class="card">
        <div class="card-h"><div><h2>IPs de confiança</h2><p>Nunca são bloqueados (nem por IP, nem por país, nem pelo modo de proteção).</p></div></div>
        <?php if ($fwAllow): ?>
        <div class="row-list">
          <?php foreach ($fwAllow as $a): ?>
            <div class="item"><span class="grow mono"><?= h($a) ?></span><form method="post" style="margin:0"><?= act_fields('fw_allow_del', ['ip' => (string)$a]) ?><button class="btn sm sec" type="submit">Remover</button></form></div>
          <?php endforeach; ?>
        </div>
        <?php endif; ?>
        <form method="post" class="card-b" style="display:flex;gap:10px;align-items:flex-end;flex-wrap:wrap">
          <?= act_fields('fw_allow_add') ?>
          <label class="fld" style="flex:1;min-width:200px">IP ou gama<input class="in mono" name="ip" required placeholder="ex.: <?= h($myIp !== '' ? $myIp : '89.155.0.10') ?>" autocomplete="off"></label>
          <button class="btn sec" type="submit">Adicionar</button>
        </form>
      </section>

  <?php else: $go = (array)($geo['ovl'] ?? []); ?>
      <div class="grid2e">
      <section class="card">
        <div class="card-h"><div><h2>Limite de ligações</h2><p>Ao chegar ao limite, o servidor deixa de aceitar ligações novas de fora do seu país, mantendo sempre margem para os visitantes nacionais.</p></div>
          <span class="pill <?= !empty($ovl['active']) ? 'p-err' : (!empty($go['on']) ? 'p-ok' : 'p-off') ?>"><?= !empty($ovl['active']) ? 'Proteção ativa' : (!empty($go['on']) ? 'Em vigilância' : 'Desligado') ?></span></div>
        <form method="post" class="card-b">
          <?= act_fields('overload_settings') ?>
          <div class="fgrid">
            <label class="fld">Estado<select class="in" name="on"><option value="on"<?= !empty($go['on']) ? ' selected' : '' ?>>Ativo</option><option value="off"<?= empty($go['on']) ? ' selected' : '' ?>>Desligado</option></select></label>
            <label class="fld">País do servidor (sempre aceite)<select class="in" name="home"><?php foreach ($allCc ?: ['PT'] as $cc): ?><option value="<?= h($cc) ?>"<?= $cc === ($geo['home'] ?? 'PT') ? ' selected' : '' ?>><?= cc_flag($cc) ?> <?= h(cc_name($cc)) ?></option><?php endforeach; ?></select></label>
            <label class="fld">Capacidade (ligações simultâneas)<input class="in" name="max" value="<?= h((string)($go['max'] ?? 'auto')) ?>" placeholder="auto"><small>auto = calculada pelo nginx: <?= (int)($go['capacity'] ?? 0) ?></small></label>
            <div class="fgrid" style="grid-template-columns:1fr 1fr">
              <label class="fld">Entrada (%)<input class="in" name="start" inputmode="numeric" pattern="[0-9]{1,2}" value="<?= (int)($go['start'] ?? 80) ?>"></label>
              <label class="fld">Saída (%)<input class="in" name="stop" inputmode="numeric" pattern="[0-9]{1,2}" value="<?= (int)($go['stop'] ?? 60) ?>"></label>
            </div>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
        <div class="card-f mu">Agora: <?= (int)($ovl['total'] ?? ($cj['total'] ?? 0)) ?> ligações. No modo de proteção continuam sempre aceites: o país do servidor, a rede local, os IPs de confiança, os IPs de onde usaste o painel nos últimos 7 dias e o DNS. Sai do modo quando a carga fica abaixo do limite de saída durante 2 minutos. Cada mudança fica na auditoria.</div>
      </section>
      <section class="card">
        <div class="card-h"><div><h2>Bloqueio automático por IP</h2><p>Bloqueia IPs com demasiadas ligações abertas em simultâneo.</p></div><span class="pill <?= !empty($fwAuto['on']) ? 'p-ok' : 'p-off' ?>"><?= !empty($fwAuto['on']) ? 'Ativo' : 'Desativado' ?></span></div>
        <form method="post" class="card-b">
          <?= act_fields('fw_auto') ?>
          <div class="fgrid" style="grid-template-columns:repeat(3,minmax(0,1fr))">
            <label class="fld">Estado<select class="in" name="on"><option value="on"<?= !empty($fwAuto['on']) ? ' selected' : '' ?>>Ativo</option><option value="off"<?= empty($fwAuto['on']) ? ' selected' : '' ?>>Desativado</option></select></label>
            <label class="fld">Limite por IP<input class="in" name="limit" inputmode="numeric" pattern="[0-9]{2,6}" required value="<?= (int)$fwAuto['limit'] ?>"></label>
            <label class="fld">Duração<select class="in" name="dur"><?php foreach ($durs as $dk => $dl): $ds = (int)fw_secs_php($dk); ?><option value="<?= h($dk) ?>"<?= $ds === $curDur ? ' selected' : '' ?>><?= h($dl) ?></option><?php endforeach; ?></select></label>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
        <div class="card-f mu">Nunca são bloqueados: este servidor, os IPs de confiança e os IPs de onde usaste o painel nos últimos 7 dias.</div>
      </section>
      </div>
  <?php endif; ?>

      <dialog id="dlg-block">
        <form method="post">
          <?= act_fields('fw_block') ?>
          <div class="dlg-h"><h3>Bloquear IP ou gama</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
          <div class="dlg-b">
            <label class="fld">IP ou gama<input class="in mono" name="ip" id="blk-ip" required placeholder="ex.: 185.220.101.47 ou 45.148.10.0/24" autocomplete="off"></label>
            <div class="fgrid">
              <label class="fld">Duração<select class="in" name="dur"><option value="1h">1 hora</option><option value="24h" selected>24 horas</option><option value="7d">7 dias</option><option value="perm">Permanente</option></select></label>
              <label class="fld">Motivo (opcional)<input class="in" name="reason" maxlength="80" autocomplete="off"></label>
            </div>
            <div class="warnbox">Fica bloqueado em todas as portas, incluindo SSH, e as ligações abertas são cortadas de imediato.</div>
          </div>
          <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn dan" type="submit">Bloquear</button></div>
        </form>
      </dialog>

<?php elseif ($page === 'cron'):
    $crons = is_array($state['crons'] ?? null) ? $state['crons'] : [];
    $cr = jload(MP_STATS . '/crons.json') ?? [];
    $runs = is_array($cr['runs'] ?? null) ? $cr['runs'] : [];
    $fSite = qget('site');
    if ($fSite !== '') $crons = array_values(array_filter($crons, function ($c) use ($fSite) { return ($c['site'] ?? '') === $fSite; }));
    $sitePorts = [];
    foreach ($sites as $s) $sitePorts[(string)$s['name']] = (int)$s['port'];
    $tzc = tz_off(live_stats());
?>
      <section class="card">
        <div class="card-h">
          <div><h2>Tarefas agendadas</h2><p>Cada tarefa corre com o utilizador do seu site. A saída fica guardada e não há sobreposição de execuções.</p></div>
          <?php if ($sites): ?>
          <form method="get" style="margin:0"><input type="hidden" name="p" value="cron">
            <select class="in" name="site" onchange="this.form.submit()" aria-label="Filtrar por site" style="height:40px;min-width:180px">
              <option value="">Todos os sites</option>
              <?php foreach ($sites as $s): $sn = (string)$s['name']; ?><option value="<?= h($sn) ?>"<?= $sn === $fSite ? ' selected' : '' ?>><?= h($sn) ?></option><?php endforeach; ?>
            </select>
          </form>
          <?php endif; ?>
        </div>
        <?php if (!$sites): ?>
          <div class="empty"><b>Ainda não há sites</b>As tarefas agendadas pertencem a um site.</div>
        <?php elseif (!$crons): ?>
          <div class="empty"><b>Sem tarefas agendadas<?= $fSite !== '' ? ' neste site' : '' ?></b>Cria uma tarefa para correr um script PHP, chamar um URL ou executar um comando.<br><button class="btn" type="button" data-cron-new><?= ic('plus') ?>Nova tarefa</button></div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Tarefa</th><th>Quando</th><th>Última execução</th><th>Estado</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php [$pgList, $pgN, $pgPages, $pgTot] = paginate($crons, 50); foreach ($pgList as $c):
                $cid = (string)($c['id'] ?? ''); $cs = (string)($c['site'] ?? ''); $on = !empty($c['on']);
                $run = $runs[$cs . ':' . $cid] ?? null; $rc = $run['rc'] ?? null; ?>
            <tr>
              <td class="first" data-label="Tarefa">
                <div class="who"><span class="av <?= tone($cs) ?>"><?= ic('clock') ?></span><div style="min-width:0">
                  <div class="nm"><?= h(($c['desc'] ?? '') !== '' ? $c['desc'] : $cs) ?></div>
                  <div class="mu mono cron-cmd" title="<?= h($c['cmd'] ?? '') ?>"><?= h($c['cmd'] ?? '') ?></div>
                </div></div>
              </td>
              <td data-label="Quando" class="cron-when"><div><?= h(cron_human((string)($c['when'] ?? ''))) ?></div><div class="mu"><span class="mono"><?= h($c['when'] ?? '') ?></span> · <?= h($cs) ?></div></td>
              <td data-label="Última execução" class="cron-when">
                <?php if ($run === null): ?><span class="mu">Ainda não correu</span>
                <?php elseif ($rc === 'running'): ?><span class="pill p-me">A correr</span> <span class="mu"><?= h(ago((int)$run['start'], time())) ?></span>
                <?php else: ?><span class="pill <?= $rc === '0' ? 'p-ok' : 'p-err' ?>"><?= $rc === '0' ? 'Sucesso' : 'Erro ' . h($rc) ?></span> <span class="mu"><?= h(ago((int)$run['end'], time())) ?> · <?= max(0, (int)$run['end'] - (int)$run['start']) ?> s</span><?php endif; ?>
              </td>
              <td data-label="Estado"><span class="pill <?= $on ? 'p-ok' : 'p-off' ?>"><?= $on ? 'Ativa' : 'Em pausa' ?></span></td>
              <td class="act r">
                <details class="dd">
                  <summary class="iconbtn" aria-label="Ações da tarefa"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <form method="post"><?= act_fields('cron_run', ['site' => $cs, 'id' => $cid]) ?><button type="submit"><?= ic('play') ?>Executar agora</button></form>
                    <button type="button" data-open="dlg-cronlog-<?= h($cid) ?>"><?= ic('file') ?>Ver saída</button>
                    <button type="button" data-cron-edit="<?= h((string)json_encode(['site' => $cs, 'id' => $cid, 'when' => $c['when'] ?? '', 'cmd' => $c['cmd'] ?? '', 'desc' => $c['desc'] ?? ''])) ?>"><?= ic('edit') ?>Editar</button>
                    <form method="post"><?= act_fields($on ? 'cron_off' : 'cron_on', ['site' => $cs, 'id' => $cid]) ?><button type="submit"><?= ic('toggle') ?><?= $on ? 'Pôr em pausa' : 'Ativar' ?></button></form>
                    <hr>
                    <form method="post" data-confirm="Apagar esta tarefa agendada?"><?= act_fields('cron_del', ['site' => $cs, 'id' => $cid]) ?><button type="submit" class="dan"><?= ic('trash') ?>Apagar</button></form>
                  </div>
                </details>
                <dialog id="dlg-cronlog-<?= h($cid) ?>" style="width:min(820px,calc(100vw - 24px))">
                  <div class="dlg-h"><div style="min-width:0"><h3>Saída da última execução</h3><p class="mono cron-cmd"><?= h($c['cmd'] ?? '') ?></p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
                  <pre class="cron-out"><?= $run !== null && ($run['tail'] ?? '') !== '' ? h($run['tail']) : 'Ainda não há saída registada.' ?></pre>
                  <div class="dlg-f"><span class="mu" style="margin-right:auto">Registo completo: /srv/www/<?= h($cs) ?>/logs/cron-<?= h($cid) ?>.log</span><button class="btn sec" type="button" data-close>Fechar</button></div>
                </dialog>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php if ($pgPages > 1): ?><div class="card-f"><?= pager($pgN, $pgPages, $pgTot, 'pg', 'tarefas') ?></div><?php endif; ?>
        <?php endif; ?>
        <div class="card-f mu">Dentro do comando, <span class="mono">php</span> usa a versão de PHP do site. O comando arranca na pasta public_html do site. A saída fica em logs/cron-&lt;id&gt;.log e o resultado é atualizado a cada minuto.</div>
      </section>

      <dialog class="drawer" id="dlg-cron" aria-labelledby="t-cron">
        <form method="post" id="cron-form">
          <?= act_fields('cron_save') ?>
          <input type="hidden" name="id" id="cron-id">
          <div class="dlg-h"><div><h3 id="t-cron">Nova tarefa agendada</h3><p>Como no cPanel: periodicidade e comando.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
          <div class="dlg-b">
            <label class="fld">Site<select class="in" name="site" id="cron-site">
              <?php foreach ($sites as $s): $sn = (string)$s['name']; ?><option value="<?= h($sn) ?>" data-port="<?= (int)$s['port'] ?>"<?= $sn === $fSite ? ' selected' : '' ?>><?= h($sn) ?></option><?php endforeach; ?>
            </select></label>
            <label class="fld">Definições comuns<select class="in" id="cron-preset">
              <option value="">— escolher —</option>
              <option value="* * * * *">A cada minuto</option>
              <option value="*/5 * * * *">A cada 5 minutos</option>
              <option value="*/15 * * * *">A cada 15 minutos</option>
              <option value="*/30 * * * *">A cada 30 minutos</option>
              <option value="0 * * * *">De hora a hora</option>
              <option value="0 */6 * * *">A cada 6 horas</option>
              <option value="0 3 * * *">Uma vez por dia (03:00)</option>
              <option value="0 3 * * 0">Uma vez por semana (domingo, 03:00)</option>
              <option value="0 3 1 * *">Uma vez por mês (dia 1, 03:00)</option>
            </select></label>
            <div class="cron-fields">
              <label class="fld">Minuto<input class="in mono" id="cf-0" value="*/5" autocomplete="off"></label>
              <label class="fld">Hora<input class="in mono" id="cf-1" value="*" autocomplete="off"></label>
              <label class="fld">Dia<input class="in mono" id="cf-2" value="*" autocomplete="off"></label>
              <label class="fld">Mês<input class="in mono" id="cf-3" value="*" autocomplete="off"></label>
              <label class="fld">Semana<input class="in mono" id="cf-4" value="*" autocomplete="off"></label>
            </div>
            <div class="mu" style="margin-top:-8px;font-size:12px">Minuto 0–59 · hora 0–23 · dia 1–31 · mês 1–12 · dia da semana 0–6 (0 = domingo). Aceita *, listas (1,15), intervalos (8-20) e passos (*/10).</div>
            <input type="hidden" name="when" id="cron-when">
            <div class="cron-human" id="cron-human"></div>
            <label class="fld">Comando<textarea class="in mono cron-ta" name="cmd" id="cron-cmd" rows="3" required maxlength="2000" spellcheck="false" placeholder="php /srv/www/loja/public_html/cron.php"></textarea></label>
            <div class="cron-help">
              <span class="mu">Inserir:</span>
              <button class="chip sm" type="button" data-ins="php">Script PHP</button>
              <button class="chip sm" type="button" data-ins="url">Chamar URL do site</button>
              <button class="chip sm" type="button" data-ins="quiet">Sem saída</button>
            </div>
            <label class="fld">Descrição (opcional)<input class="in" name="desc" id="cron-desc" maxlength="80" placeholder="ex.: Cron do PrestaShop" autocomplete="off"></label>
          </div>
          <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit" id="cron-submit">Criar tarefa</button></div>
        </form>
      </dialog>

<?php elseif ($page === 'backups'):
    $bk = jload(MP_STATS . '/backup.json') ?? [];
    $bkRun = jload(MP_STATS . '/backup-run.json');
    $bkConf = is_array($bk['conf'] ?? null) ? $bk['conf'] : ['enabled' => true, 'time' => '03:00', 'keep_daily' => 7, 'keep_weekly' => 4, 'keep_monthly' => 3, 'remote' => ''];
    $bkSets = is_array($bk['sets'] ?? null) ? $bk['sets'] : [];
    $bkRem = is_array($bk['remotes'] ?? null) ? $bk['remotes'] : [];
    $bkLast = is_array($bk['last'] ?? null) ? $bk['last'] : null;
    $tzb = tz_off(live_stats());
    $fSet = qget('set');
    if ($fSet !== '') $bkSets = array_values(array_filter($bkSets, function ($x) use ($fSet) { return ($x['site'] ?? '') === $fSet; }));
    $setName = function (string $s): string { return $s === '_bd' ? 'Bases de dados sem site' : ($s === '_sistema' ? 'Configuração do sistema' : $s); };
    $typeName = ['auto' => ['Automático', 'p-off'], 'manual' => ['Manual', 'p-me'], 'pre-restauro' => ['Antes de repor', 'p-err']];
    $next = '';
    if (!empty($bkConf['enabled'])) {
        [$hh, $mm] = array_map('intval', explode(':', (string)$bkConf['time'] . ':0'));
        $loc = time() + $tzb; $today = intdiv($loc, 86400) * 86400 + $hh * 3600 + $mm * 60;
        $next = gmdate('d/m H:i', $today > $loc ? $today : $today + 86400);
    }
?>
      <?php if ($bkRun): ?>
        <div class="card bk-run" data-bk-running><div class="row-list"><div class="item"><span class="spin"></span><div class="grow"><div class="nm">Backup em curso</div><div class="mu"><?= h($bkRun['step'] ?? '') ?> · desde há <?= max(1, (int)ceil((time() - (int)($bkRun['since'] ?? time())) / 60)) ?> min</div></div><span class="mu">A página atualiza sozinha.</span></div></div></div>
      <?php endif; ?>
<?php $btab = in_array(qget('t'), ['copias', 'config'], true) ? qget('t') : 'copias'; ?>
      <nav class="tabs" aria-label="Secções"><a class="chip<?= $btab === 'copias' ? ' prim' : '' ?>" href="?p=backups&amp;t=copias">Cópias</a><a class="chip<?= $btab === 'config' ? ' prim' : '' ?>" href="?p=backups&amp;t=config">Agendamento e destinos</a></nav>
<?php if ($btab === 'copias'): ?>
      <section class="stats">
        <div class="stat"><span class="tile <?= $bkLast && empty($bkLast['ok']) ? 't-warn' : 't-acc' ?>"><?= ic('archive') ?></span><div><div class="k">Último backup</div><div class="v"><?= $bkLast ? (empty($bkLast['ok']) ? 'Com erros' : 'Sucesso') : '—' ?> <small><?= $bkLast ? h(ago((int)$bkLast['ts'], time())) : 'ainda não houve' ?></small></div></div></div>
        <div class="stat"><span class="tile t-blue"><?= ic('clock') ?></span><div><div class="k">Próximo automático</div><div class="v"><?= $next !== '' ? h($next) : 'Desativado' ?></div></div></div>
        <div class="stat"><span class="tile t-vio"><?= ic('db') ?></span><div><div class="k">Espaço ocupado (local)</div><div class="v"><?= h(fmt_bytes((float)($bk['total'] ?? 0))) ?> <small><?= count($bk['sets'] ?? []) ?> backups</small></div></div></div>
        <div class="stat"><span class="tile t-warn"><?= ic('upload') ?></span><div><div class="k">Cópia remota</div><div class="v"><?= ($bkConf['remote'] ?? '') !== '' ? h($bkConf['remote']) : 'Só local' ?></div></div></div>
      </section>
      <?php if ($bkLast && empty($bkLast['ok'])): ?><div class="card"><div class="card-b" style="color:var(--err)"><?= h($bkLast['msg'] ?? '') ?></div></div><?php endif; ?>

      <section class="card">
        <div class="card-h">
          <div><h2>Backups guardados</h2><p>Cada backup de um site inclui os ficheiros, as bases de dados associadas e as tarefas agendadas.</p></div>
          <form method="get" style="margin:0"><input type="hidden" name="p" value="backups">
            <select class="in" name="set" onchange="this.form.submit()" aria-label="Filtrar" style="height:40px;min-width:200px">
              <option value="">Todos</option>
              <?php foreach ($sites as $s): $sn = (string)$s['name']; ?><option value="<?= h($sn) ?>"<?= $sn === $fSet ? ' selected' : '' ?>><?= h($sn) ?></option><?php endforeach; ?>
              <option value="_bd"<?= $fSet === '_bd' ? ' selected' : '' ?>>Bases de dados sem site</option>
              <option value="_sistema"<?= $fSet === '_sistema' ? ' selected' : '' ?>>Configuração do sistema</option>
            </select>
          </form>
        </div>
        <?php if (!$bkSets): ?>
          <div class="empty"><b>Ainda não há backups<?= $fSet !== '' ? ' deste conjunto' : '' ?></b>Faz o primeiro agora ou espera pelo backup automático.<br><button class="btn" type="button" data-open="dlg-bk-now"><?= ic('archive') ?>Fazer backup agora</button></div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Conjunto</th><th>Data</th><th>Tipo</th><th>Conteúdo</th><th class="r">Tamanho</th><th>Remoto</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php [$pgList, $pgN, $pgPages, $pgTot] = paginate($bkSets, 30); foreach ($pgList as $i => $b): $bs = (string)($b['site'] ?? ''); $bid = (string)($b['id'] ?? ''); $tn = $typeName[$b['type'] ?? 'manual'] ?? ['Manual', 'p-me'];
                $dbl = is_array($b['dbs'] ?? null) ? $b['dbs'] : []; $did = 'bk' . $i; ?>
            <tr>
              <td class="first" data-label="Conjunto"><div class="who"><span class="av <?= $bs[0] === '_' ? 't-vio' : tone($bs) ?>"><?= $bs[0] === '_' ? ic($bs === '_bd' ? 'db' : 'server') : h(substr($bs, 0, 1)) ?></span><div class="nm"><?= h($setName($bs)) ?></div></div></td>
              <td data-label="Data"><?= h(gmdate('d/m/Y H:i', (int)($b['created'] ?? 0) + $tzb)) ?></td>
              <td data-label="Tipo"><span class="pill <?= $tn[1] ?>"><?= $tn[0] ?></span></td>
              <td data-label="Conteúdo" class="mu"><?= h(implode(' + ', array_filter([!empty($b['files']) ? ($bs === '_sistema' ? 'Configuração' : 'Ficheiros') : '', $dbl ? count($dbl) . ' BD' : '']))) ?: '—' ?></td>
              <td class="r" data-label="Tamanho"><?= h(fmt_bytes((float)($b['size'] ?? 0))) ?></td>
              <td data-label="Remoto"><?= ($b['remote'] ?? '') !== '' ? '<span class="pill p-ok">' . h($b['remote']) . '</span>' : '<span class="mu">—</span>' ?></td>
              <td class="act r">
                <details class="dd">
                  <summary class="iconbtn" aria-label="Ações do backup"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <?php if ($bs !== '_sistema'): ?><button type="button" data-open="dlg-rs-<?= $did ?>"><?= ic('reload') ?>Repor…</button><?php endif; ?>
                    <?php if (!empty($b['files'])): $ff = $bs === '_sistema' ? 'sistema.tar.gz' : 'ficheiros.tar.gz'; ?><a href="?bk=dl&amp;s=<?= h(rawurlencode($bs)) ?>&amp;id=<?= h($bid) ?>&amp;f=<?= $ff ?>"><?= ic('download') ?>Descarregar <?= $bs === '_sistema' ? 'configuração' : 'ficheiros' ?></a><?php endif; ?>
                    <?php foreach ($dbl as $d): ?><a href="?bk=dl&amp;s=<?= h(rawurlencode($bs)) ?>&amp;id=<?= h($bid) ?>&amp;f=bd-<?= h(rawurlencode((string)$d)) ?>.sql.gz"><?= ic('download') ?>Descarregar BD <?= h($d) ?></a><?php endforeach; ?>
                    <hr>
                    <form method="post" data-confirm="Apagar este backup (cópia local)?"><?= act_fields('bk_del', ['s' => $bs, 'id' => $bid]) ?><button type="submit" class="dan"><?= ic('trash') ?>Apagar</button></form>
                  </div>
                </details>
                <?php if ($bs !== '_sistema'): ?>
                <dialog id="dlg-rs-<?= $did ?>">
                  <form method="post">
                    <?= act_fields('bk_restore', ['s' => $bs, 'id' => $bid]) ?>
                    <div class="dlg-h"><h3>Repor <?= h($setName($bs)) ?></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
                    <div class="dlg-b">
                      <p class="mu" style="margin:0">Backup de <?= h(gmdate('d/m/Y H:i', (int)($b['created'] ?? 0) + $tzb)) ?>.</p>
                      <?php if ($bs !== '_bd'): ?>
                      <label class="chk"><input type="radio" name="what" value="all" checked> Tudo: ficheiros, bases de dados e tarefas agendadas</label>
                      <label class="chk"><input type="radio" name="what" value="files"> Só os ficheiros (public_html)</label>
                      <?php if ($dbl): ?><label class="chk"><input type="radio" name="what" value="db"> Só as bases de dados (<?= h(implode(', ', $dbl)) ?>)</label><?php endif; ?>
                      <?php else: ?><input type="hidden" name="what" value="db"><p style="margin:0">Repõe as bases de dados: <?= h(implode(', ', $dbl)) ?>.</p><?php endif; ?>
                      <div class="warnbox">O conteúdo atual é substituído. Antes de repor é feito automaticamente um backup do estado atual ("Antes de repor"), para poderes voltar atrás.</div>
                      <label class="chk"><input type="checkbox" name="ok" value="1" required> Compreendo que o conteúdo atual vai ser substituído</label>
                    </div>
                    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn dan" type="submit">Repor backup</button></div>
                  </form>
                </dialog>
                <?php endif; ?>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php if ($pgPages > 1): ?><div class="card-f"><?= pager($pgN, $pgPages, $pgTot, 'pg', 'backups') ?></div><?php endif; ?>
        <?php endif; ?>
        <div class="card-f mu">Local: /var/backups/minipainel. As bases de dados só entram no backup de um site se estiverem associadas a ele (página Bases de dados); as restantes vão para "Bases de dados sem site".</div>
      </section>

<?php endif; if ($btab === 'config'): ?>
      <div class="bk-cfg">
        <section class="card">
          <div class="card-h"><div><h2>Agendamento e retenção</h2><p>Backup automático diário de todos os sites e bases de dados.</p></div><span class="pill <?= !empty($bkConf['enabled']) ? 'p-ok' : 'p-off' ?>"><?= !empty($bkConf['enabled']) ? 'Ativo' : 'Desativado' ?></span></div>
          <form method="post" class="card-b">
            <?= act_fields('bk_conf') ?>
            <div class="fgrid">
              <label class="fld">Estado<select class="in" name="on"><option value="on"<?= !empty($bkConf['enabled']) ? ' selected' : '' ?>>Ativo</option><option value="off"<?= empty($bkConf['enabled']) ? ' selected' : '' ?>>Desativado</option></select></label>
              <label class="fld">Hora<input class="in" type="time" name="time" required value="<?= h($bkConf['time'] ?? '03:00') ?>"></label>
            </div>
            <div class="fgrid" style="grid-template-columns:repeat(3,minmax(0,1fr));margin-top:14px">
              <label class="fld">Diários<input class="in" name="daily" inputmode="numeric" pattern="[0-9]{1,3}" required value="<?= (int)$bkConf['keep_daily'] ?>"></label>
              <label class="fld">Semanais<input class="in" name="weekly" inputmode="numeric" pattern="[0-9]{1,3}" required value="<?= (int)$bkConf['keep_weekly'] ?>"></label>
              <label class="fld">Mensais<input class="in" name="monthly" inputmode="numeric" pattern="[0-9]{1,3}" required value="<?= (int)$bkConf['keep_monthly'] ?>"></label>
            </div>
            <label class="fld" style="margin-top:14px">Cifrar as cópias remotas<select class="in" name="encrypt"><option value="on"<?= ($bkConf['encrypt'] ?? true) ? ' selected' : '' ?>>Sim (AES-256, recomendado)</option><option value="off"<?= ($bkConf['encrypt'] ?? true) ? '' : ' selected' ?>>Não</option></select><small>O destino remoto só vê ficheiros cifrados; a chave fica neste servidor</small></label>
            <label class="fld" style="margin-top:14px">Cópia remota<select class="in" name="remote"><option value="none">Só local</option><?php foreach ($bkRem as $r): ?><option value="<?= h($r['name']) ?>"<?= ($bkConf['remote'] ?? '') === $r['name'] ? ' selected' : '' ?>><?= h($r['name']) ?> (<?= h($r['type']) ?>)</option><?php endforeach; ?></select></label>
            <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
          </form>
          <div class="card-f" style="display:flex;align-items:center;gap:12px;flex-wrap:wrap"><span class="mu" style="flex:1;min-width:220px">Guarda a <b>chave dos backups</b> fora deste servidor: é precisa para repor cópias remotas noutro servidor.</span><button class="btn sm sec" type="button" data-open="dlg-bk-key"><?= ic('key') ?>Mostrar chave</button></div>
          <dialog id="dlg-bk-key"><form method="post"><?= act_fields('bk_key_show') ?>
            <div class="dlg-h"><h3>Chave dos backups</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
            <div class="dlg-b"><label class="fld">Confirma com a password do painel<input class="in" type="password" name="atual" required autocomplete="current-password"></label><p class="mu" style="margin:0">A chave aparece numa notificação; copia-a para um gestor de passwords.</p></div>
            <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Mostrar</button></div>
          </form></dialog>
          <div class="card-f mu">A retenção aplica-se ao local e ao remoto: por exemplo, 7 diários, 4 semanais e 3 mensais cobrem cerca de 3 meses. Os backups manuais ficam até os apagares. Se o disco passar de 90%, o backup é cancelado e o erro aparece aqui.</div>
        </section>

        <section class="card">
          <div class="card-h"><div><h2>Destinos remotos</h2><p>SFTP, S3 (Backblaze, Wasabi, MinIO, AWS…) ou qualquer destino do rclone.</p></div><button class="chip sm soft" type="button" data-open="dlg-bk-remote">Adicionar destino</button></div>
          <?php if (!$bkRem): ?>
            <div class="empty">Sem destinos remotos. Os backups ficam só neste servidor.</div>
          <?php else: ?>
          <div class="row-list">
            <?php foreach ($bkRem as $r): ?>
              <div class="item">
                <span class="av t-blue"><?= ic('upload') ?></span>
                <div class="grow"><div class="nm"><?= h($r['name']) ?> <span class="pill p-off"><?= h(strtoupper((string)$r['type'])) ?></span></div><div class="mu mono"><?= h($r['root']) ?>/<?= h($sys['hostname'] ?? 'servidor') ?>/…</div></div>
                <div class="svc-acts">
                  <form method="post"><?= act_fields('bk_remote_test', ['name' => (string)$r['name']]) ?><button class="btn sm sec" type="submit">Testar</button></form>
                  <form method="post" data-confirm="Remover o destino <?= h($r['name']) ?>? Os backups já enviados não são apagados."><?= act_fields('bk_remote_del', ['name' => (string)$r['name']]) ?><button class="btn sm sec" type="submit">Remover</button></form>
                </div>
              </div>
            <?php endforeach; ?>
          </div>
          <?php endif; ?>
        </section>
      </div>

<?php endif; ?>
      <dialog id="dlg-bk-now">
        <form method="post">
          <?= act_fields('bk_now') ?>
          <div class="dlg-h"><h3>Fazer backup agora</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
          <div class="dlg-b">
            <label class="fld">O que guardar<select class="in" name="target">
              <option value="all">Tudo (todos os sites, bases de dados e configuração)</option>
              <?php foreach ($sites as $s): $sn = (string)$s['name']; ?><option value="<?= h($sn) ?>">Site <?= h($sn) ?></option><?php endforeach; ?>
              <option value="_bd">Bases de dados sem site</option>
              <option value="_sistema">Configuração do sistema</option>
            </select></label>
            <?php if ($bkRem): ?>
            <label class="fld">Enviar também para<select class="in" name="remote"><option value="">Não enviar (só local)</option><?php foreach ($bkRem as $r): ?><option value="<?= h($r['name']) ?>"<?= ($bkConf['remote'] ?? '') === $r['name'] ? ' selected' : '' ?>><?= h($r['name']) ?></option><?php endforeach; ?></select></label>
            <?php endif; ?>
            <p class="mu" style="margin:0">Corre em segundo plano; podes continuar a usar o painel. Os backups manuais não são apagados pela retenção.</p>
          </div>
          <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Iniciar backup</button></div>
        </form>
      </dialog>

      <dialog class="drawer" id="dlg-bk-remote">
        <form method="post" autocomplete="off">
          <?= act_fields('bk_remote_add') ?>
          <div class="dlg-h"><div><h3>Adicionar destino remoto</h3><p>As credenciais ficam só neste servidor (/etc/minipainel, acesso root).</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
          <div class="dlg-b">
            <div class="fgrid">
              <label class="fld">Nome<input class="in" name="name" required pattern="[a-z][a-z0-9\-]{1,23}" placeholder="ex.: storagebox"></label>
              <label class="fld">Tipo<select class="in" name="type" id="rm-type"><option value="sftp">SFTP</option><option value="s3">S3 compatível</option><option value="rclone">Outro (configuração rclone)</option></select></label>
            </div>
            <div data-rm="sftp" class="rm-grp">
              <div class="fgrid">
                <label class="fld">Servidor<input class="in" name="host" placeholder="backup.exemplo.pt"></label>
                <label class="fld">Porta<input class="in" name="port" value="22" inputmode="numeric"></label>
                <label class="fld">Utilizador<input class="in" name="user"></label>
                <label class="fld">Password<input class="in" type="password" name="pass" autocomplete="new-password"><small>Ou usa uma chave privada abaixo</small></label>
              </div>
              <label class="fld">Chave privada (opcional)<textarea class="in mono cron-ta" name="key" rows="3" placeholder="-----BEGIN OPENSSH PRIVATE KEY-----"></textarea></label>
              <label class="fld">Pasta no servidor<input class="in mono" name="path_sftp" value="backups"></label>
            </div>
            <div data-rm="s3" class="rm-grp" hidden>
              <div class="fgrid">
                <label class="fld">Fornecedor<select class="in" name="provider"><option value="Other">Outro / MinIO / Backblaze B2 (S3)</option><option value="Wasabi">Wasabi</option><option value="AWS">Amazon S3</option><option value="Cloudflare">Cloudflare R2</option><option value="DigitalOcean">DigitalOcean Spaces</option></select></label>
                <label class="fld">Região<input class="in" name="region" placeholder="eu-central-1"></label>
              </div>
              <label class="fld">Endpoint<input class="in mono" name="endpoint" placeholder="s3.eu-central-003.backblazeb2.com"><small>Vazio para Amazon S3</small></label>
              <div class="fgrid">
                <label class="fld">Chave de acesso<input class="in mono" name="access"></label>
                <label class="fld">Chave secreta<input class="in mono" type="password" name="secret" autocomplete="new-password"></label>
                <label class="fld">Bucket<input class="in mono" name="bucket"></label>
                <label class="fld">Prefixo (opcional)<input class="in mono" name="path_s3" placeholder="servidores"></label>
              </div>
            </div>
            <div data-rm="rclone" class="rm-grp" hidden>
              <label class="fld">Configuração rclone<textarea class="in mono cron-ta" name="config" rows="7" placeholder="[nome]&#10;type = drive&#10;scope = drive&#10;token = {...}"></textarea><small>Para Google Drive, OneDrive, Dropbox…: corre "rclone config" no teu PC e cola aqui a secção gerada. O nome entre [ ] tem de ser igual ao nome acima.</small></label>
              <label class="fld">Pasta no destino<input class="in mono" name="path_rc" value="iddigital-hosting"></label>
            </div>
          </div>
          <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Adicionar</button></div>
        </form>
      </dialog>

<?php elseif ($page === 'definicoes'):
    $srvMode = (string)($srv['mode'] ?? 'lan');
?>
<?php $dtab = in_array(qget('t'), ['servidor', 'seguranca', 'servicos'], true) ? qget('t') : 'servidor'; ?>
      <nav class="tabs" aria-label="Secções"><a class="chip<?= $dtab === 'servidor' ? ' prim' : '' ?>" href="?p=definicoes&amp;t=servidor">Servidor e domínio</a><a class="chip<?= $dtab === 'seguranca' ? ' prim' : '' ?>" href="?p=definicoes&amp;t=seguranca">Acesso e segurança</a><a class="chip<?= $dtab === 'servicos' ? ' prim' : '' ?>" href="?p=definicoes&amp;t=servicos">Serviços</a></nav>
<?php if ($dtab === 'servidor'): ?>
      <section class="card">
        <div class="card-h"><div><h2>Modo do servidor</h2><p>Define como o painel apresenta os sites e o que propõe por omissão. Mudar de modo não altera os sites que já existem.</p></div></div>
        <form method="post" class="card-b">
          <?= act_fields('srv_mode') ?>
          <div class="mode-grid">
            <label class="mode<?= $srvMode === 'lan' ? ' on' : '' ?>"><input type="radio" name="mode" value="lan"<?= $srvMode === 'lan' ? ' checked' : '' ?>>
              <span class="tile t-blue"><?= ic('server') ?></span>
              <b>LAN</b><span class="mu">Sites acessíveis por IP e porta (http://IP:8001). Ideal para redes internas, testes e desenvolvimento. Os domínios são opcionais e o SSL é autoassinado.</span></label>
            <label class="mode<?= $srvMode === 'internet' ? ' on' : '' ?>"><input type="radio" name="mode" value="internet"<?= $srvMode === 'internet' ? ' checked' : '' ?>>
              <span class="tile t-acc"><?= ic('world') ?></span>
              <b>Internet</b><span class="mu">Sites com domínio próprio nas portas 80/443 e certificado Let's Encrypt automático. Cada site continua também acessível pela porta.</span></label>
          </div>
          <div class="fgrid" style="margin-top:18px">
            <label class="fld">Email para o Let's Encrypt<input class="in" type="email" name="email" value="<?= h($srv['email'] ?? '') ?>" placeholder="ssl@iddigital.pt"><small>Recebe os avisos de expiração dos certificados (opcional)</small></label>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
        <div class="card-f mu">No modo Internet, cada domínio tem de ter um registo DNS (A ou AAAA) a apontar para o IP público deste servidor, e as portas 80 e 443 têm de chegar a ele (se houver router ou firewall à frente, reencaminha essas portas).</div>
      </section>

<?php endif; if ($dtab === 'seguranca'): ?>
      <div class="grid2e">
      <section class="card">
        <div class="card-h"><div><h2>Acesso pelas portas dos sites</h2><p>As portas próprias (ex.: :8001) servem os sites em HTTP, sem SSL.</p></div><span class="pill <?= ($srv['ports_access'] ?? 'all') === 'lan' ? 'p-ok' : 'p-off' ?>"><?= ($srv['ports_access'] ?? 'all') === 'lan' ? 'Só rede local' : 'Todos' ?></span></div>
        <form method="post" class="card-b">
          <?= act_fields('ports_access') ?>
          <label class="chk"><input type="radio" name="pa" value="all"<?= ($srv['ports_access'] ?? 'all') !== 'lan' ? ' checked' : '' ?>> Abertas a qualquer IP</label>
          <label class="chk" style="margin-top:8px"><input type="radio" name="pa" value="lan"<?= ($srv['ports_access'] ?? 'all') === 'lan' ? ' checked' : '' ?>> Só rede local (10.x, 172.16-31.x, 192.168.x) e IPs de confiança</label>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
        <div class="card-f mu">Recomendado no modo Internet: os sites ficam públicos só pelos domínios (80/443, com HTTPS). Os IPs de confiança definem-se na página Ligações.</div>
      </section>

      <section class="card">
        <div class="card-h"><div><h2>IPs autorizados no painel</h2><p>Se preencheres, o painel (incluindo phpMyAdmin e ficheiros) só abre a partir destes IPs.</p></div><span class="pill <?= ($srv['panel_allow'] ?? '') !== '' ? 'p-ok' : 'p-off' ?>"><?= ($srv['panel_allow'] ?? '') !== '' ? 'Restrito' : 'Todos' ?></span></div>
        <form method="post" class="card-b">
          <?= act_fields('panel_allow') ?>
          <label class="fld">IPs ou redes (um por linha)<textarea class="in mono cron-ta" name="ips" rows="4" placeholder="<?= h($myIp) ?>&#10;192.168.1.0/24"><?= h(str_replace(' ', "\n", (string)($srv['panel_allow'] ?? ''))) ?></textarea><small>O teu IP atual é <b class="mono"><?= h($myIp) ?></b> e tem de estar incluído. Vazio = qualquer IP.</small></label>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
        <div class="card-f mu">Se ficares sem acesso, na consola do servidor: <span class="mono">mpanel panel-allow none</span></div>
      </section>
      </div>

      <section class="card">
        <div class="card-h"><div><h2>Proteção contra força bruta</h2><p>Bloqueia na firewall os IPs com demasiadas passwords erradas. Os bloqueios aparecem e desbloqueiam-se na página Ligações.</p></div>
          <?php $pr = is_array($state['protect'] ?? null) ? $state['protect'] : ['ssh' => true, 'ssh_fails' => 5, 'panel_fails' => 10, 'auth_fails' => 10, 'window' => 10, 'ban1' => '1h', 'ban2' => '24h', 'ban3' => '7d', 'recent' => 0]; ?>
          <span class="pill p-ok"><?= (int)$pr['recent'] ?> bloqueio<?= (int)$pr['recent'] === 1 ? '' : 's' ?> nas últimas 24 h</span></div>
        <form method="post" class="card-b">
          <?= act_fields('protect_settings') ?>
          <div class="fgrid" style="grid-template-columns:repeat(4,minmax(0,1fr))">
            <label class="fld">SSH (falhas)<input class="in" name="ssh_fails" inputmode="numeric" pattern="[0-9]{1,3}" value="<?= (int)$pr['ssh_fails'] ?>"><small>Todas as contas, incluindo o root</small></label>
            <label class="fld">Painel (falhas)<input class="in" name="panel_fails" inputmode="numeric" pattern="[0-9]{1,3}" value="<?= (int)$pr['panel_fails'] ?>"><small>Password ou código 2FA errados</small></label>
            <label class="fld">Email, webmail e FTP (falhas)<input class="in" name="auth_fails" inputmode="numeric" pattern="[0-9]{1,3}" value="<?= (int)$pr['auth_fails'] ?>"></label>
            <label class="fld">Janela (minutos)<input class="in" name="window" inputmode="numeric" pattern="[0-9]{1,4}" value="<?= (int)$pr['window'] ?>"><small>Período em que as falhas contam</small></label>
          </div>
          <?php $durs = ['15m' => '15 minutos', '1h' => '1 hora', '6h' => '6 horas', '24h' => '24 horas', '7d' => '7 dias', '30d' => '30 dias', 'perm' => 'Permanente']; $sel = function (string $cur, array $opts) use ($durs) { $o = ''; foreach ($opts as $k) $o .= '<option value="' . $k . '"' . ($cur === $k ? ' selected' : '') . '>' . $durs[$k] . '</option>'; return $o; }; ?>
          <div class="fgrid" style="grid-template-columns:repeat(4,minmax(0,1fr));margin-top:14px">
            <label class="fld">1.º bloqueio<select class="in" name="ban1"><?= $sel((string)$pr['ban1'], ['15m', '1h', '6h', '24h']) ?></select></label>
            <label class="fld">2.º bloqueio (30 dias)<select class="in" name="ban2"><?= $sel((string)$pr['ban2'], ['6h', '24h', '7d']) ?></select></label>
            <label class="fld">3.º e seguintes<select class="in" name="ban3"><?= $sel((string)$pr['ban3'], ['7d', '30d', 'perm']) ?></select></label>
            <label class="fld">Vigiar o SSH<select class="in" name="ssh"><option value="on"<?= !empty($pr['ssh']) ? ' selected' : '' ?>>Sim</option><option value="off"<?= empty($pr['ssh']) ? ' selected' : '' ?>>Não</option></select></label>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
        <div class="card-f mu">Nunca são bloqueados o próprio servidor, os IPs de confiança (página Ligações) nem os IPs de onde usaste o painel nos últimos 7 dias. Quem volta a ser apanhado em 30 dias fica bloqueado mais tempo.</div>
      </section>

<?php endif; if ($dtab === 'servicos'): ?>
      <section class="card">
        <div class="card-h"><div><h2>Logs dos sites</h2><p>Durante quanto tempo se guardam os logs de acessos, erros e scripts lentos de cada site (rodados e comprimidos todos os dias).</p></div></div>
        <form method="post" class="card-b" style="display:flex;gap:10px;align-items:center;flex-wrap:wrap"><?= act_fields('logs_settings') ?><span>Logs dos sites: guardar</span><input class="in" name="days" inputmode="numeric" pattern="[0-9]{1,3}" value="<?= (int)($state['log_days'] ?? 90) ?>" style="width:90px"><span>dias</span><button class="btn sm sec" type="submit">Guardar</button></form>
      </section>
      <?php $pg2 = is_array($state['perf'] ?? null) ? $state['perf'] : []; ?>
      <section class="card">
        <div class="card-h"><div><h2>Rede e compressão</h2><p>Ajustes do servidor que tornam os sites mais rápidos para todos os visitantes.</p></div></div>
        <div class="row-list">
          <div class="item"><div class="grow"><div class="nm">Rede afinada (TCP BBR) <span class="pill <?= ($pg2['cc'] ?? '') === 'bbr' ? 'p-ok' : 'p-off' ?>"><?= h((string)($pg2['cc'] ?? '—')) ?></span></div><div class="mu">Controlo de congestionamento BBR e filas de ligação maiores: páginas mais rápidas sobretudo em redes móveis e visitantes distantes.</div></div>
            <form method="post"><?= act_fields('net_tune', ['on' => !empty($pg2['net']) ? 'off' : 'on']) ?><button class="btn sm <?= !empty($pg2['net']) ? 'sec' : '' ?>" type="submit"><?= !empty($pg2['net']) ? 'Desligar' : 'Ligar' ?></button></form></div>
          <div class="item"><div class="grow"><div class="nm">Compressão Brotli <span class="pill <?= !empty($pg2['brotli']) ? 'p-ok' : 'p-off' ?>"><?= !empty($pg2['brotli']) ? 'Ligada' : 'Desligada' ?></span></div><div class="mu">HTML, CSS e JS cerca de 15–20% mais pequenos do que com gzip (que continua ativo para os browsers sem Brotli).<?= empty($pg2['brotli_ok']) && empty($pg2['brotli']) ? ' O módulo é instalado ao ligar.' : '' ?></div></div>
            <form method="post"><?= act_fields('brotli', ['on' => !empty($pg2['brotli']) ? 'off' : 'on']) ?><button class="btn sm <?= !empty($pg2['brotli']) ? 'sec' : '' ?>" type="submit"><?= !empty($pg2['brotli']) ? 'Desligar' : 'Ligar' ?></button></form></div>
        </div>
      </section>

      <div class="grid2e">
      <section class="card">
        <div class="card-h"><div><h2>phpMyAdmin</h2><p>Tempos e limites. Aumenta-os para importar ou exportar bases de dados grandes.</p></div></div>
        <form method="post" class="card-b">
          <?= act_fields('pma_settings') ?>
          <?php $ps = is_array($state['pma_settings'] ?? null) ? $state['pma_settings'] : ['session' => 120, 'exec' => 600, 'upload' => 512]; ?>
          <div class="fgrid" style="grid-template-columns:repeat(3,minmax(0,1fr))">
            <label class="fld">Sessão (minutos)<input class="in" name="session" inputmode="numeric" pattern="[0-9]{1,4}" value="<?= (int)$ps['session'] ?>"><small>Sem atividade até pedir login (5 a 1440)</small></label>
            <label class="fld">Tempo por operação (s)<input class="in" name="exec" inputmode="numeric" pattern="[0-9]{1,4}" value="<?= (int)$ps['exec'] ?>"><small>Importações e consultas longas (30 a 7200)</small></label>
            <label class="fld">Importação máxima (MB)<input class="in" name="upload" inputmode="numeric" pattern="[0-9]{1,4}" value="<?= (int)$ps['upload'] ?>"><small>Tamanho do ficheiro (8 a 4096)</small></label>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
      </section>
      <section class="card">
        <div class="card-h"><div><h2>FTP</h2><p>Acesso por FTPS (porta 21) e SFTP (porta 22). As contas ativam-se em Sites → ⋮ → Acesso FTP/SFTP.</p></div><span class="pill <?= !empty($state['ftp']['installed']) ? 'p-ok' : 'p-off' ?>"><?= !empty($state['ftp']['installed']) ? 'Instalado' : 'Ainda não usado' ?></span></div>
        <form method="post" class="card-b">
          <?= act_fields('ftp_settings') ?>
          <label class="fld">IP público para o modo passivo<input class="in mono" name="pasv_ip" value="<?= h($state['ftp']['pasv_ip'] ?? '') ?>" placeholder="vazio = o próprio servidor"><small>Preenche se o servidor estiver atrás de um router com NAT (reencaminha a porta 21 e as portas 30000-30100)</small></label>
          <label class="chk" style="margin-top:12px"><input type="checkbox" name="plain" value="1"<?= !empty($state['ftp']['plain']) ? ' checked' : '' ?>> Permitir também FTP sem cifra (não recomendado: a password circula em claro)</label>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
      </section>
      </div>

<?php endif; if ($dtab === 'servidor'): ?>
      <section class="card">
        <div class="card-h"><div><h2>Domínio do painel</h2><p>Acesso ao painel por um nome, por exemplo hosting.iddigital.pt, com certificado válido.</p></div>
          <?php if (($srv['panel_domain'] ?? '') !== ''): ?><span class="pill p-ok"><?= h($srv['panel_domain']) ?></span><?php endif; ?></div>
        <form method="post" class="card-b">
          <?= act_fields('panel_domain') ?>
          <div class="fgrid">
            <label class="fld">Domínio<input class="in mono" name="domain" value="<?= h($srv['panel_domain'] ?? '') ?>" placeholder="hosting.iddigital.pt" autocomplete="off"><small>Vazio = sem domínio (o painel fica só na porta <?= (int)($sys['panel_port'] ?? 2443) ?>)</small></label>
            <label class="fld">Certificado<select class="in" name="ssl"><option value="le"<?= ($srv['panel_ssl'] ?? 'le') === 'le' ? ' selected' : '' ?>>Let's Encrypt</option><option value="self"<?= ($srv['panel_ssl'] ?? '') === 'self' ? ' selected' : '' ?>>Autoassinado (LAN)</option></select></label>
          </div>
          <?php if (!empty($srv['panel_ssl_exp'])): ?><p class="mu" style="margin:12px 0 0">Certificado válido até <?= h(gmdate('d/m/Y', (int)$srv['panel_ssl_exp'] + tz_off(live_stats()))) ?>; é renovado automaticamente.</p><?php endif; ?>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
      </section>

<?php endif; ?>
<?php elseif ($page === 'email'):
    $ml = is_array($state['mail'] ?? null) ? $state['mail'] : ['enabled' => false];
    $mOn = !empty($ml['enabled']);
    $tab = in_array(qget('t'), ['caixas', 'envio', 'fila', 'spam', 'antispam'], true) ? qget('t') : 'caixas';
    $mHist = is_array($ml['history'] ?? null) ? $ml['history'] : [];
    $mLists = is_array($ml['lists'] ?? null) ? $ml['lists'] : [];
    $mHost = (string)($ml['host'] ?? '');
    $mDomains = is_array($ml['domains'] ?? null) ? $ml['domains'] : [];
    $mBoxes = is_array($ml['boxes'] ?? null) ? $ml['boxes'] : [];
    $mAliases = is_array($ml['aliases'] ?? null) ? $ml['aliases'] : [];
    $mSites = is_array($ml['sites'] ?? null) ? $ml['sites'] : [];
    $mQueue = is_array($ml['queue'] ?? null) ? $ml['queue'] : [];
    $chk = function ($v): string { return $v === null ? '<span class="pill p-off">?</span>' : (!empty($v['ok']) ? '<span class="pill p-ok">OK</span>' : '<span class="pill p-err">Falta</span>'); };
?>
<?php if (!$mOn): ?>
      <section class="card">
        <div class="card-h"><div><h2>Ativar o email</h2><p>Caixas de correio (IMAP/POP3/SMTP), envio do mail() dos sites e antispam.</p></div></div>
        <form method="post" class="card-b">
          <?= act_fields('mail_enable') ?>
          <div class="fgrid">
            <label class="fld">Nome do servidor de correio<input class="in mono" name="host" required placeholder="mail.iddigital.pt" autocomplete="off"><small>Tem de ter um registo A a apontar para este servidor; é o nome que os clientes de email usam</small></label>
          </div>
          <?php if (!$isNet): ?><div class="warnbox" style="margin-top:14px">O servidor está em modo LAN. O email funciona para testes internos, mas para receber e entregar email na internet muda para o modo Internet (Definições).</div><?php endif; ?>
          <div class="warnbox" style="margin-top:14px">Antes de ativar, confirma com o fornecedor do servidor que a <b>porta 25 de saída</b> está desbloqueada e pede o <b>PTR (DNS inverso)</b> do IP para o nome acima. Sem isto, o email enviado vai para o spam ou é recusado.</div>
          <div style="margin-top:16px"><button class="btn" type="submit">Instalar e ativar o email</button> <span class="mu">Instala Postfix, Dovecot, Rspamd, Redis e Unbound (alguns minutos).</span></div>
        </form>
      </section>
<?php else: ?>
      <nav class="tabs" aria-label="Secções do email">
        <?php foreach (['caixas' => 'Domínios e caixas', 'envio' => 'Envio dos sites', 'fila' => 'Fila (' . count($mQueue) . ')', 'spam' => 'Spam e listas', 'antispam' => 'Antispam'] as $tk => $tl): ?>
          <a class="chip<?= $tab === $tk ? ' prim' : '' ?>" href="?p=email&amp;t=<?= $tk ?>"><?= h($tl) ?></a>
        <?php endforeach; ?>
        <span class="mu" style="margin-left:auto">Servidor: <b class="mono"><?= h($mHost) ?></b> <?= !empty($ml['services_ok']) ? '<span class="pill p-ok">Serviços OK</span>' : '<span class="pill p-err">Serviço parado</span>' ?></span>
      </nav>

  <?php if ($tab === 'caixas'): ?>
      <section class="card wm-card"><div class="row-list"><div class="item">
        <span class="tile t-acc"><?= ic('mail') ?></span>
        <div class="grow"><div class="nm">Webmail</div><div class="mu">Os utilizadores entram com o endereço e a password da caixa. Em Definições → Respostas automáticas configuram férias/ausência; em Filtros, regras próprias.</div></div>
        <a class="btn" href="<?= h($ml['webmail'] ?? '#') ?>" target="_blank" rel="noopener"><?= ic('ext') ?><?= h(preg_replace('#^https://#', '', (string)($ml['webmail'] ?? ''))) ?></a>
      </div></div></section>

      <section class="card">
        <div class="card-h"><div><h2>Domínios de email</h2><p>Cada domínio tem a sua chave DKIM. Cria os registos DNS e usa "Verificar".</p></div><button class="chip sm soft" type="button" data-open="dlg-md-new">Adicionar domínio</button></div>
        <?php if (!$mDomains): ?><div class="empty"><b>Ainda não há domínios</b>Adiciona o primeiro domínio para criar caixas de correio.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Domínio</th><th>Caixas</th><th>MX</th><th>SPF</th><th>DKIM</th><th>DMARC</th><th>PTR</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($mDomains as $i => $md): $dn = (string)$md['name']; $dd = is_array($md['dns'] ?? null) ? $md['dns'] : null; ?>
            <tr>
              <td class="first" data-label="Domínio"><div class="who"><span class="av <?= tone($dn) ?>"><?= ic('mail') ?></span><div class="nm"><?= h($dn) ?></div></div></td>
              <td data-label="Caixas"><?= (int)$md['boxes'] ?></td>
              <td data-label="MX"><?= $chk($dd['mx'] ?? null) ?></td><td data-label="SPF"><?= $chk($dd['spf'] ?? null) ?></td><td data-label="DKIM"><?= $chk($dd['dkim'] ?? null) ?></td>
              <td data-label="DMARC"><?= $chk($dd['dmarc'] ?? null) ?></td><td data-label="PTR"><?= $chk($dd['ptr'] ?? null) ?></td>
              <td class="act r">
                <details class="dd"><summary class="iconbtn" aria-label="Ações de <?= h($dn) ?>"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <button type="button" data-open="dlg-md-dns-<?= $i ?>"><?= ic('world') ?>Registos DNS</button>
                    <form method="post"><?= act_fields('mail_dns_check', ['d' => $dn]) ?><button type="submit"><?= ic('reload') ?>Verificar DNS</button></form>
                    <hr>
                    <form method="post" data-confirm="Apagar o domínio <?= h($dn) ?> com TODAS as caixas de correio e mensagens? Não é possível desfazer."><?= act_fields('mail_dom_del', ['d' => $dn]) ?><button type="submit" class="dan"><?= ic('trash') ?>Apagar</button></form>
                  </div></details>
                <dialog id="dlg-md-dns-<?= $i ?>" style="width:min(980px,calc(100vw - 24px))">
                  <div class="dlg-h"><div><h3>Registos DNS de <?= h($dn) ?></h3><p>Cria estes registos na zona DNS do domínio.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
                  <div class="dlg-b">
                    <?php $ip = (string)($dd['ip'] ?? ''); $recs = [
                        ['MX', $dn, '10 ' . $mHost, $dd['mx'] ?? null],
                        ['TXT', $dn, 'v=spf1 mx a:' . $mHost . ' ~all', $dd['spf'] ?? null],
                        ['TXT', 'mp._domainkey.' . $dn, (string)($md['dkim'] ?? ''), $dd['dkim'] ?? null],
                        ['TXT', '_dmarc.' . $dn, 'v=DMARC1; p=quarantine; adkim=s; aspf=s; rua=mailto:postmaster@' . $dn, $dd['dmarc'] ?? null],
                        ['A', $mHost, $ip !== '' ? $ip : 'IP público do servidor', $dd['a'] ?? null],
                        ['PTR', $ip !== '' ? $ip : 'IP do servidor', $mHost . ' (pedir ao fornecedor)', $dd['ptr'] ?? null]]; ?>
                    <table class="list dnsrec"><thead><tr><th>Tipo</th><th>Nome</th><th>Valor</th><th>Estado</th></tr></thead><tbody>
                    <?php foreach ($recs as $r): ?><tr><td class="mono"><?= h($r[0]) ?></td><td class="mono"><?= h($r[1]) ?></td><td><div class="dnsval mono"><?= h($r[2]) ?></div></td><td><?= $chk($r[3]) ?></td></tr><?php endforeach; ?>
                    </tbody></table>
                    <?php if ($dd !== null): ?><p class="mu" style="margin:0">Última verificação: <?= h(ago((int)($dd['checked'] ?? 0), time())) ?>. As alterações de DNS podem demorar algumas horas a propagar.</p><?php endif; ?>
                  </div>
                  <div class="dlg-f"><form method="post"><?= act_fields('mail_dns_check', ['d' => $dn]) ?><button class="btn" type="submit">Verificar agora</button></form><button class="btn sec" type="button" data-close>Fechar</button></div>
                </dialog>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
      </section>

      <section class="card">
        <div class="card-h"><div><h2>Caixas de correio</h2><p>IMAP <span class="mono"><?= h($mHost) ?>:993</span> · POP3 <span class="mono">:995</span> · SMTP <span class="mono">:465</span> (SSL) ou <span class="mono">:587</span> (STARTTLS) · utilizador = endereço completo</p></div><?php if ($mDomains): ?><button class="chip sm soft" type="button" data-open="dlg-mb-new">Nova caixa</button><?php endif; ?></div>
        <?php if (!$mBoxes): ?><div class="empty">Ainda não há caixas de correio.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Endereço</th><th>Ocupação</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($mBoxes as $i => $b): $em = (string)$b['email']; $q = max(1, (int)$b['quota']); $u = (int)$b['used']; $pc = min(100, (int)round($u * 100 / $q)); ?>
            <tr>
              <td class="first" data-label="Endereço"><div class="who"><span class="av <?= tone($em) ?>"><?= h(strtoupper(substr($em, 0, 1))) ?></span><div class="nm"><?= h($em) ?></div></div></td>
              <td data-label="Ocupação" style="min-width:220px"><div class="bar"><span style="width:<?= $pc ?>%"<?= $pc >= 90 ? ' class="hot"' : '' ?>></span></div><div class="mu"><?= $u ?> MB de <?= $q ?> MB</div></td>
              <td class="act r">
                <details class="dd"><summary class="iconbtn" aria-label="Ações de <?= h($em) ?>"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <button type="button" data-open="dlg-mb-<?= $i ?>"><?= ic('key') ?>Password e quota</button>
                    <hr>
                    <form method="post" data-confirm="Apagar a caixa <?= h($em) ?> e todas as mensagens?"><?= act_fields('mail_box_del', ['email' => $em]) ?><button type="submit" class="dan"><?= ic('trash') ?>Apagar</button></form>
                  </div></details>
                <dialog id="dlg-mb-<?= $i ?>"><form method="post"><?= act_fields('mail_box_set', ['email' => $em]) ?>
                  <div class="dlg-h"><h3><?= h($em) ?></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
                  <div class="dlg-b"><div class="fgrid">
                    <label class="fld">Nova password<input class="in" type="password" name="pw" minlength="10" autocomplete="new-password"><small>Vazio = não altera</small></label>
                    <label class="fld">Quota (MB)<input class="in" name="quota" inputmode="numeric" pattern="[0-9]{2,7}" value="<?= $q ?>"></label>
                  </div></div>
                  <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Guardar</button></div>
                </form></dialog>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
      </section>

      <section class="card">
        <div class="card-h"><div><h2>Encaminhamentos e aliases</h2><p>Endereços que reencaminham para outras caixas (internas ou externas). Usa <span class="mono">@dominio.pt</span> para receber todos os endereços.</p></div><?php if ($mDomains): ?><button class="chip sm soft" type="button" data-open="dlg-ma-new">Novo encaminhamento</button><?php endif; ?></div>
        <?php if (!$mAliases): ?><div class="empty">Sem encaminhamentos.</div>
        <?php else: ?>
        <div class="row-list">
          <?php foreach ($mAliases as $a): ?>
            <div class="item"><span class="av t-vio"><?= ic('mail') ?></span><div class="grow"><div class="nm mono"><?= h($a['alias']) ?></div><div class="mu">→ <?= h(implode(', ', (array)$a['dests'])) ?></div></div>
              <form method="post" data-confirm="Apagar o encaminhamento <?= h($a['alias']) ?>?"><?= act_fields('mail_alias_del', ['alias' => (string)$a['alias']]) ?><button class="btn sm sec" type="submit">Apagar</button></form></div>
          <?php endforeach; ?>
        </div>
        <?php endif; ?>
      </section>

      <dialog id="dlg-md-new"><form method="post"><?= act_fields('mail_dom_add') ?>
        <div class="dlg-h"><h3>Adicionar domínio de email</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
        <div class="dlg-b"><label class="fld">Domínio<input class="in mono" name="d" required placeholder="iddigital.pt" autocomplete="off"><small>É gerada uma chave DKIM; depois cria os registos DNS indicados</small></label></div>
        <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Adicionar</button></div>
      </form></dialog>
      <dialog class="drawer" id="dlg-mb-new"><form method="post" autocomplete="off"><?= act_fields('mail_box_add') ?>
        <div class="dlg-h"><div><h3>Nova caixa de correio</h3><p>O utilizador para os clientes de email é o endereço completo.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
        <div class="dlg-b">
          <div class="fgrid">
            <label class="fld">Nome<input class="in mono" name="user" required pattern="[a-z0-9]([a-z0-9._+\-]{0,62}[a-z0-9])?" placeholder="geral"></label>
            <label class="fld">Domínio<select class="in" name="dom"><?php foreach ($mDomains as $md): ?><option value="<?= h($md['name']) ?>">@<?= h($md['name']) ?></option><?php endforeach; ?></select></label>
            <label class="fld">Password<input class="in" type="password" name="pw" minlength="10" autocomplete="new-password"><small>Vazio = gerada e mostrada no fim</small></label>
            <label class="fld">Quota (MB)<input class="in" name="quota" inputmode="numeric" pattern="[0-9]{2,7}" value="1024"></label>
          </div>
        </div>
        <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Criar caixa</button></div>
      </form></dialog>
      <dialog id="dlg-ma-new"><form method="post"><?= act_fields('mail_alias_set') ?>
        <div class="dlg-h"><h3>Novo encaminhamento</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
        <div class="dlg-b">
          <label class="fld">Endereço<input class="in mono" name="alias" required placeholder="info@iddigital.pt ou @iddigital.pt"></label>
          <label class="fld">Encaminhar para<textarea class="in mono cron-ta" name="dests" rows="3" required placeholder="geral@iddigital.pt&#10;outro@gmail.com"></textarea><small>Um por linha (até 20)</small></label>
        </div>
        <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Guardar</button></div>
      </form></dialog>

  <?php elseif ($tab === 'envio'): ?>
      <section class="card">
        <div class="card-h"><div><h2>Envio de email pelos sites</h2><p>O mail() do PHP de cada site passa por uma fila do painel: limite por hora, análise antispam e DKIM antes de sair. Se um site for comprometido e começar a enviar spam, o envio dele é suspenso automaticamente sem afetar os outros.</p></div></div>
        <table class="list cards">
          <thead><tr><th>Site</th><th class="r">Última hora</th><th class="r">24 h</th><th class="r">Limite/hora</th><th class="r">Retidos</th><th class="r">Rejeitados (spam)</th><th>Estado</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($mSites as $i => $ms): $sn = (string)$ms['site']; $lim = $ms['limit'] ?? null; ?>
            <tr>
              <td class="first" data-label="Site"><div class="who"><span class="av <?= tone($sn) ?>"><?= h(substr($sn, 0, 1)) ?></span><div class="nm"><?= h($sn) ?></div></div></td>
              <td class="r" data-label="Última hora"><?= (int)$ms['sent_1h'] ?></td>
              <td class="r" data-label="24 h"><?= (int)$ms['sent_24h'] ?></td>
              <td class="r" data-label="Limite/hora"><?= $lim === null ? (int)($ml['site_limit'] ?? 100) . ' <span class="mu">(geral)</span>' : (int)$lim ?></td>
              <td class="r" data-label="Retidos"><?= (int)$ms['held'] ?></td>
              <td class="r" data-label="Rejeitados"><?= (int)$ms['rejected'] > 0 ? '<b style="color:var(--err)">' . (int)$ms['rejected'] . '</b>' : '0' ?></td>
              <td data-label="Estado"><?= !empty($ms['suspended']) ? '<span class="pill p-err">Suspenso</span><div class="mu">' . h($ms['why'] ?? '') . '</div>' : '<span class="pill p-ok">Ativo</span>' ?></td>
              <td class="act r">
                <details class="dd"><summary class="iconbtn" aria-label="Ações de <?= h($sn) ?>"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <button type="button" data-open="dlg-msl-<?= $i ?>"><?= ic('sliders') ?>Mudar limite</button>
                    <?php if (!empty($ms['suspended'])): ?><form method="post"><?= act_fields('mail_site', ['site' => $sn, 'op' => 'resume']) ?><button type="submit"><?= ic('play') ?>Retomar envio</button></form>
                    <?php else: ?><form method="post"><?= act_fields('mail_site', ['site' => $sn, 'op' => 'suspend']) ?><button type="submit"><?= ic('ban') ?>Suspender envio</button></form><?php endif; ?>
                    <hr>
                    <form method="post" data-confirm="Apagar as mensagens retidas e rejeitadas de <?= h($sn) ?>?"><?= act_fields('mail_site', ['site' => $sn, 'op' => 'purge']) ?><button type="submit" class="dan"><?= ic('trash') ?>Apagar retidos</button></form>
                  </div></details>
                <dialog id="dlg-msl-<?= $i ?>"><form method="post"><?= act_fields('mail_site', ['site' => $sn, 'op' => 'limit']) ?>
                  <div class="dlg-h"><h3>Limite de envio de <?= h($sn) ?></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
                  <div class="dlg-b"><label class="fld">Emails por hora<input class="in" name="limit" inputmode="numeric" pattern="[0-9]{1,6}" value="<?= (int)($lim ?? ($ml['site_limit'] ?? 100)) ?>"><small>Acima do limite as mensagens ficam retidas e saem na hora seguinte</small></label></div>
                  <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Guardar</button></div>
                </form></dialog>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <div class="card-f mu">Os sites não podem usar a porta 25 nem o sendmail diretamente (bloqueado na firewall e no Postfix). O remetente só é aceite se for de um domínio do próprio site; caso contrário é usado <span class="mono">&lt;site&gt;@<?= h($mHost) ?></span>. Ao fim de 5 mensagens com spam numa hora, o envio do site é suspenso.</div>
      </section>

  <?php elseif ($tab === 'spam'): ?>
      <section class="card">
        <div class="card-h"><div><h2>Mensagens rejeitadas ou marcadas como spam</h2><p>Últimas mensagens que o antispam recusou (rejeitada) ou entregou na pasta Lixo (spam). Se for um falso positivo, permite o remetente ou o domínio.</p></div></div>
        <?php if (!$mHist): ?><div class="empty">Sem mensagens rejeitadas ou marcadas como spam recentemente.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Data</th><th>Remetente</th><th>Destinatário</th><th>Assunto</th><th class="r">Pontos</th><th>Resultado</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($mHist as $i => $hm): $fr = strtolower(trim((string)preg_replace('/^.*<|>.*$/', '', (string)($hm['from'] ?? '')))); ?>
            <tr>
              <td class="first" data-label="Data"><span class="mono"><?= h(gmdate('d/m H:i', (int)($hm['t'] ?? 0) + tz_off(live_stats()))) ?></span></td>
              <td class="mono" data-label="Remetente"><?= h($fr) ?><div class="mu"><?= h($hm['ip'] ?? '') ?></div></td>
              <td class="mono" data-label="Destinatário"><?= h($hm['to'] ?? '') ?></td>
              <td data-label="Assunto" style="max-width:280px"><?= h(mb_strimwidth((string)($hm['subject'] ?? ''), 0, 80, '…')) ?><div class="mu mono" style="font-size:11px"><?= h(implode(' ', (array)($hm['symbols'] ?? []))) ?></div></td>
              <td class="r" data-label="Pontos"><?= h(number_format((float)($hm['score'] ?? 0), 1, ',', '')) ?></td>
              <td data-label="Resultado"><?= ($hm['action'] ?? '') === 'reject' ? '<span class="pill p-err">Rejeitada</span>' : '<span class="pill p-warn">Lixo</span>' ?></td>
              <td class="act r">
                <?php if (filter_var($fr, FILTER_VALIDATE_EMAIL)): ?>
                <details class="dd"><summary class="iconbtn" aria-label="Ações"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <form method="post"><?= act_fields('mail_list', ['l' => 'allow', 'op' => 'add', 'v' => $fr]) ?><button type="submit"><?= ic('check') ?>Permitir este remetente</button></form>
                    <form method="post"><?= act_fields('mail_list', ['l' => 'allow', 'op' => 'add', 'v' => '@' . substr($fr, strpos($fr, '@') + 1)]) ?><button type="submit"><?= ic('check') ?>Permitir o domínio @<?= h(substr($fr, strpos($fr, '@') + 1)) ?></button></form>
                    <hr>
                    <form method="post"><?= act_fields('mail_list', ['l' => 'deny', 'op' => 'add', 'v' => $fr]) ?><button type="submit" class="dan"><?= ic('ban') ?>Bloquear este remetente</button></form>
                  </div></details>
                <?php endif; ?>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
        <div class="card-f mu">As mensagens rejeitadas não chegam a ser aceites (o remetente recebe o aviso de erro); as marcadas como spam vão para a pasta Lixo de cada caixa. Quando um utilizador move uma mensagem para o Lixo, ou a tira de lá, o antispam aprende com isso.</div>
      </section>

      <section class="card">
        <div class="card-h"><div><h2>Listas de remetentes</h2><p>Permitidos passam sempre o antispam; bloqueados são sempre rejeitados. Aceita endereços, @domínios e IPs.</p></div></div>
        <form method="post" class="card-b" style="display:flex;gap:10px;flex-wrap:wrap;align-items:flex-end">
          <?= act_fields('mail_list', ['op' => 'add']) ?>
          <label class="fld" style="flex:1;min-width:240px">Endereço, @domínio ou IP<input class="in mono" name="v" required placeholder="faturas@fornecedor.pt, @fornecedor.pt ou 203.0.113.5"></label>
          <label class="fld">Lista<select class="in" name="l"><option value="allow">Permitir</option><option value="deny">Bloquear</option></select></label>
          <button class="btn" type="submit" style="height:44px">Adicionar</button>
        </form>
        <?php if ($mLists): ?>
        <div class="row-list">
          <?php foreach ($mLists as $li): ?>
            <div class="item"><span class="pill <?= $li['list'] === 'allow' ? 'p-ok' : 'p-err' ?>"><?= $li['list'] === 'allow' ? 'Permitido' : 'Bloqueado' ?></span><div class="grow mono"><?= h($li['value']) ?></div>
              <form method="post"><?= act_fields('mail_list', ['l' => (string)$li['list'], 'op' => 'del', 'v' => (string)$li['value']]) ?><button class="btn sm sec" type="submit">Remover</button></form></div>
          <?php endforeach; ?>
        </div>
        <?php endif; ?>
      </section>

  <?php elseif ($tab === 'fila'): ?>
      <section class="card">
        <div class="card-h"><div><h2>Fila de correio</h2><p>Mensagens que o Postfix ainda não conseguiu entregar (servidor de destino indisponível, recusa temporária…).</p></div>
          <div style="display:flex;gap:8px"><form method="post"><?= act_fields('mail_queue', ['op' => 'flush']) ?><button class="btn sm sec" type="submit">Reenviar tudo</button></form>
          <?php if ($mQueue): ?><form method="post" data-confirm="Apagar todas as mensagens da fila?"><?= act_fields('mail_queue', ['op' => 'all']) ?><button class="btn sm dan" type="submit">Esvaziar</button></form><?php endif; ?></div></div>
        <?php if (!$mQueue): ?><div class="empty">A fila está vazia.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Remetente</th><th>Destinatário</th><th>Motivo</th><th>Há</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($mQueue as $qm): ?>
            <tr>
              <td class="first mono" data-label="Remetente"><?= h($qm['from'] ?? '') ?></td>
              <td class="mono" data-label="Destinatário"><?= h($qm['to'] ?? '') ?></td>
              <td data-label="Motivo" class="mu" style="max-width:420px"><?= h($qm['why'] ?? '') ?></td>
              <td data-label="Há"><?= h(ago((int)($qm['t'] ?? time()), time())) ?></td>
              <td class="act r"><form method="post"><?= act_fields('mail_queue', ['op' => 'del', 'id' => (string)($qm['id'] ?? '')]) ?><button class="btn sm sec" type="submit">Apagar</button></form></td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
      </section>

  <?php else: ?>
      <div class="grid2e">
      <section class="card">
        <div class="card-h"><div><h2>Antispam</h2><p>Postscreen + Rspamd: SPF, DKIM, DMARC, reputação, greylisting e listas negras.</p></div></div>
        <form method="post" class="card-b">
          <?= act_fields('mail_settings') ?>
          <label class="fld">Listas negras próprias (DNSBL)<textarea class="in mono cron-ta" name="dnsbl" rows="3" placeholder="dnsbl.3rhost.pt"><?= h(str_replace(' ', "\n", (string)($ml['dnsbl'] ?? ''))) ?></textarea><small>Uma zona por linha. Juntam-se à Spamhaus ZEN, Barracuda, SpamCop e PSBL.</small></label>
          <div class="fgrid" style="margin-top:14px">
            <label class="fld">Limite por site (emails/hora)<input class="in" name="site_limit" inputmode="numeric" pattern="[0-9]{1,5}" value="<?= (int)($ml['site_limit'] ?? 100) ?>"></label>
            <label class="fld">Limite por caixa (emails/hora)<input class="in" name="box_limit" inputmode="numeric" pattern="[0-9]{1,5}" value="<?= (int)($ml['box_limit'] ?? 200) ?>"></label>
            <label class="fld">Bloquear IP após falhas de login (10 min)<input class="in" name="auth_fails" inputmode="numeric" pattern="[0-9]{1,5}" value="<?= (int)($ml['auth_fails'] ?? 10) ?>"><small>O IP fica bloqueado 1 hora em todas as portas</small></label>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
        <div class="card-f mu">As listas negras são consultadas através de um resolver DNS próprio (Unbound), porque a Spamhaus não responde a resolvers públicos.</div>
      </section>
      <section class="card">
        <div class="card-h"><div><h2>Antivírus</h2><p>ClamAV analisa os anexos de todo o email que entra e sai.</p></div><span class="pill <?= !empty($ml['clamav']) ? 'p-ok' : 'p-off' ?>"><?= !empty($ml['clamav']) ? 'Ativo' : 'Desativado' ?></span></div>
        <form method="post" class="card-b"<?= empty($ml['clamav']) ? '' : ' data-confirm="Desativar o antivírus?"' ?>>
          <?= act_fields('mail_av', ['op' => !empty($ml['clamav']) ? 'off' : 'on']) ?>
          <button class="btn<?= !empty($ml['clamav']) ? ' sec' : '' ?>" type="submit"><?= !empty($ml['clamav']) ? 'Desativar' : 'Ativar antivírus' ?></button>
        </form>
        <div class="card-f mu">Usa cerca de 1,2 GB de RAM. Confirma na página Recursos que o servidor tem memória livre suficiente.</div>
      </section>
      </div>
  <?php endif; ?>
<?php endif; ?>

<?php elseif ($page === 'atualizacoes'):
    $up = jload(MP_STATS . '/update.json') ?? [];
    $upLast = jload(MP_STATS . '/update-last.json');
    $osu = jload(MP_STATS . '/os-updates.json') ?? [];
    $upRun = jload(MP_STATS . '/update-run.json');
    $snaps = is_array($state['updates']['snaps'] ?? null) ? $state['updates']['snaps'] : [];
    $hasKey = !empty($up['key']);
    $pk = is_array($osu['packages'] ?? null) ? $osu['packages'] : [];
?>
      <?php if ($upRun): ?>
        <div class="card bk-run" data-bk-running><div class="row-list"><div class="item"><span class="spin"></span><div class="grow"><div class="nm"><?= ($upRun['kind'] ?? '') === 'sistema' ? 'Atualização do sistema em curso' : 'Atualização do painel em curso' ?></div><div class="mu"><?= h($upRun['step'] ?? '') ?> · há <?= max(1, (int)ceil((time() - (int)($upRun['since'] ?? time())) / 60)) ?> min</div></div><span class="mu">A página atualiza sozinha. O painel pode ficar indisponível alguns segundos.</span></div></div></div>
      <?php elseif ($upLast && (int)($upLast['ts'] ?? 0) > time() - 86400 && (!empty($upLast['ok']) || !preg_match('/para (\d+(?:\.\d+)+)/', (string)($upLast['msg'] ?? ''), $upM) || version_compare($upM[1], MP_VERSION, '>'))): ?>
        <div class="card"><div class="card-b" style="color:<?= !empty($upLast['ok']) ? 'var(--ok)' : 'var(--err)' ?>"><b><?= !empty($upLast['ok']) ? 'Concluído' : 'Falhou' ?>:</b> <?= h($upLast['msg'] ?? '') ?> <span class="mu">(<?= h(ago((int)$upLast['ts'], time())) ?>)</span></div></div>
      <?php endif; ?>

<?php $utab = in_array(qget('t'), ['painel', 'sistema'], true) ? qget('t') : 'painel'; ?>
      <nav class="tabs" aria-label="Secções"><a class="chip<?= $utab === 'painel' ? ' prim' : '' ?>" href="?p=atualizacoes&amp;t=painel">Painel</a><a class="chip<?= $utab === 'sistema' ? ' prim' : '' ?>" href="?p=atualizacoes&amp;t=sistema">Sistema operativo</a></nav>
<?php if ($utab === 'painel'): ?>
      <div class="up-cfg">
      <section class="card">
        <div class="card-h"><div><h2>Painel</h2><p>Versão do IDDigital Hosting e atualizações publicadas no GitHub.</p></div>
          <?php if (!empty($up['newer'])): ?><span class="pill p-warn">Versão nova disponível</span><?php elseif (!empty($up['latest'])): ?><span class="pill p-ok">Atualizado</span><?php endif; ?></div>
        <div class="card-b">
          <div class="kv"><span>Instalada</span><b>v<?= h(MP_VERSION) ?></b></div>
          <div class="kv"><span>Publicada</span><b><?= !empty($up['latest']) ? 'v' . h($up['latest']) . (!empty($up['date']) ? ' <span class="mu">(' . h($up['date']) . ')</span>' : '') : '—' ?></b></div>
          <div class="kv"><span>Verificação</span><b><?= $hasKey ? '<span class="pill p-ok">Assinatura obrigatória</span>' : '<span class="pill p-err">Sem chave de assinatura</span>' ?></b></div>
          <div class="kv"><span>Última procura</span><b><?= !empty($up['checked']) ? h(ago((int)$up['checked'], time())) : 'nunca' ?></b></div>
          <?php if (!empty($up['error'])): ?><p style="color:var(--err);margin:12px 0 0"><?= h($up['error']) ?></p><?php endif; ?>
          <?php if (!empty($up['newer']) && ($up['notes'] ?? '') !== ''): ?><div class="fsec">Novidades da v<?= h($up['latest']) ?></div><pre class="cron-out" style="padding:12px 14px;border-radius:12px;max-height:220px"><?= h($up['notes']) ?></pre><?php endif; ?>
          <div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:16px">
            <form method="post"><?= act_fields('update_check') ?><button class="btn sec" type="submit"><?= ic('reload') ?>Procurar atualizações</button></form>
            <?php if (!empty($up['newer'])): ?>
            <form method="post" data-confirm="Atualizar o painel para a v<?= h($up['latest']) ?>? É guardada uma cópia da versão atual e, se algo falhar, é reposta automaticamente."><?= act_fields('update_start') ?>
              <?php if (!$hasKey): ?><label class="chk" style="margin-bottom:8px"><input type="checkbox" name="unsigned" value="1" required> Instalar sem assinatura<?= !empty($up['sha256']) ? ' (SHA-256 <span class="mono">' . h(substr((string)$up['sha256'], 0, 16)) . '…</span>)' : '' ?>: confirmo que publiquei esta versão</label><div class="fgrid" style="margin-bottom:10px"><?= reauth_fields($auth) ?></div><?php endif; ?>
              <button class="btn" type="submit"><?= ic('download') ?>Atualizar para v<?= h($up['latest']) ?></button></form>
            <?php endif; ?>
          </div>
        </div>
        <div class="card-f mu">Antes de atualizar: verifica a assinatura e o SHA-256, guarda uma cópia do painel e da configuração e, depois, confirma que o painel responde. Se não responder, repõe a versão anterior sozinho. Os sites, bases de dados, email e backups não são tocados.</div>
      </section>

      <div class="grid2e" style="align-items:stretch">
      <section class="card">
        <div class="card-h"><div><h2>Repositório no GitHub</h2><p>De onde vêm as atualizações. Com um token só de leitura, o repositório pode ficar sempre privado.</p></div>
          <span class="pill <?= !empty($up['token']) ? 'p-ok' : 'p-off' ?>"><?= !empty($up['token']) ? 'Token configurado' : 'Sem token (repositório público)' ?></span></div>
        <form method="post" class="card-b">
          <?= act_fields('update_token', ['op' => 'set']) ?>
          <label class="fld">Token do GitHub (só leitura)<input class="in mono" type="password" name="token" required autocomplete="off" placeholder="github_pat_…"><small>GitHub → Settings → Developer settings → Fine-grained tokens: só este repositório, permissão "Contents: Read-only". Fica guardado só para o root.</small></label>
          <div class="fgrid" style="margin-top:12px"><?= reauth_fields($auth) ?></div>
          <div style="display:flex;gap:8px;margin-top:14px"><button class="btn" type="submit"><?= !empty($up['token']) ? 'Substituir token' : 'Guardar token' ?></button></div>
        </form>
        <?php if (!empty($up['token'])): ?><form method="post" class="card-f" data-confirm="Remover o token? Se o repositório for privado, deixa de ser possível procurar atualizações."><?= act_fields('update_token', ['op' => 'clear']) ?><div class="fgrid" style="margin-bottom:10px"><?= reauth_fields($auth) ?></div><button class="btn sm sec" type="submit">Remover token</button></form><?php endif; ?>
      </section>

      <section class="card">
        <div class="card-h"><div><h2>Chave de assinatura</h2><p>Chave pública Ed25519 com que as versões são assinadas. Só são instaladas versões assinadas pela chave privada correspondente.</p></div><span class="pill <?= $hasKey ? 'p-ok' : 'p-err' ?>"><?= $hasKey ? 'Configurada' : 'Em falta' ?></span></div>
        <form method="post" class="card-b">
          <?= act_fields('update_key', ['op' => 'set']) ?>
          <label class="fld">Chave pública (PEM)<textarea class="in mono cron-ta" name="pem" rows="4" required placeholder="-----BEGIN PUBLIC KEY-----&#10;MCowBQYDK2VwAyEA…&#10;-----END PUBLIC KEY-----"></textarea><small>Gerada no teu computador com <span class="mono">release.sh keygen</span>; a chave privada nunca vem para o servidor</small></label>
          <div class="fgrid" style="margin-top:14px"><?= reauth_fields($auth) ?></div>
          <div style="display:flex;gap:8px;margin-top:14px"><button class="btn" type="submit"><?= $hasKey ? 'Substituir chave' : 'Guardar chave' ?></button></div>
        </form>
        <?php if ($hasKey): ?><form method="post" class="card-f" data-confirm="Remover a chave? As atualizações deixam de ser verificadas."><?= act_fields('update_key', ['op' => 'clear']) ?><div class="fgrid" style="margin-bottom:10px"><?= reauth_fields($auth) ?></div><button class="btn sm sec" type="submit">Remover chave</button></form><?php endif; ?>
      </section>
      </div>
      </div>

<?php endif; if ($utab === 'sistema'): ?>
      <section class="card">
        <div class="card-h"><div><h2>Sistema operativo</h2><p>Pacotes do sistema (nginx, PHP, MariaDB, email…) instalados pelo <?= h(($sys['os'] ?? '') !== '' ? $sys['os'] : 'sistema') ?>.</p></div>
          <div style="display:flex;gap:8px;align-items:center">
            <?php if (!empty($osu['reboot'])): ?><span class="pill p-warn">Precisa de reiniciar</span><?php endif; ?>
            <span class="pill <?= !empty($osu['auto']) ? 'p-ok' : 'p-off' ?>">Automáticas: <?= !empty($osu['auto']) ? 'segurança' : 'desligadas' ?></span>
          </div></div>
        <section class="stats" style="padding:0 26px">
          <div class="stat"><span class="tile t-blue"><?= ic('download') ?></span><div><div class="k">Disponíveis</div><div class="v"><?= isset($osu['total']) ? (int)$osu['total'] : '—' ?></div></div></div>
          <div class="stat"><span class="tile <?= !empty($osu['security']) ? 't-warn' : 't-acc' ?>"><?= ic('lock') ?></span><div><div class="k">De segurança</div><div class="v"><?= isset($osu['security']) ? (int)$osu['security'] : '—' ?></div></div></div>
          <div class="stat"><span class="tile t-vio"><?= ic('clock') ?></span><div><div class="k">Última procura</div><div class="v" style="font-size:16px"><?= !empty($osu['checked']) ? h(ago((int)$osu['checked'], time())) : 'nunca' ?></div></div></div>
        </section>
        <div class="card-b" style="display:flex;gap:8px;flex-wrap:wrap">
          <form method="post"><?= act_fields('os_check') ?><button class="btn sec" type="submit"><?= ic('reload') ?>Procurar</button></form>
          <?php if (!empty($osu['security'])): ?><form method="post" data-confirm="Instalar as atualizações de segurança do sistema?"><?= act_fields('os_start', ['op' => 'security']) ?><button class="btn" type="submit">Instalar as de segurança (<?= (int)$osu['security'] ?>)</button></form><?php endif; ?>
          <?php if (!empty($osu['total'])): ?><form method="post" data-confirm="Instalar todas as atualizações do sistema? Os serviços podem reiniciar por breves segundos."><?= act_fields('os_start', ['op' => 'all']) ?><button class="btn sec" type="submit">Instalar todas (<?= (int)$osu['total'] ?>)</button></form><?php endif; ?>
          <form method="post"><?= act_fields('os_auto', ['op' => !empty($osu['auto']) ? 'off' : 'on']) ?><button class="btn sec" type="submit"><?= !empty($osu['auto']) ? 'Desligar automáticas' : 'Ativar atualizações de segurança automáticas' ?></button></form>
          <?php if (!empty($osu['reboot'])): ?><button class="btn dan" type="button" data-open="dlg-reboot"><?= ic('reload') ?>Reiniciar o servidor</button><?php endif; ?>
        </div>
        <?php if ($pk): ?>
        <table class="list cards">
          <thead><tr><th>Pacote</th><th>Versão nova</th><th>Tipo</th></tr></thead>
          <tbody>
          <?php foreach (array_slice($pk, 0, 60) as $p): ?>
            <tr><td class="first mono" data-label="Pacote"><?= h($p['name'] ?? '') ?></td><td class="mono mu" data-label="Versão"><?= h($p['version'] ?? '') ?></td><td data-label="Tipo"><?= !empty($p['security']) ? '<span class="pill p-warn">Segurança</span>' : '<span class="pill p-off">Normal</span>' ?></td></tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php if (count($pk) > 60): ?><div class="card-f mu">E mais <?= count($pk) - 60 ?> pacotes.</div><?php endif; ?>
        <?php endif; ?>
        <div class="card-f mu">As atualizações automáticas instalam só as de segurança e nunca reiniciam o servidor sozinhas. A procura é feita todos os dias de madrugada.</div>
      </section>

      <?php if ($snaps): ?>
<?php endif; if ($utab === 'painel'): ?>
      <section class="card">
        <div class="card-h"><div><h2>Cópias anteriores do painel</h2><p>Guardadas antes de cada atualização (painel, configuração e serviços). Repor volta a pôr essa versão do painel.</p></div></div>
        <div class="row-list">
          <?php foreach ($snaps as $sn): $fn = (string)$sn['file']; ?>
            <div class="item"><span class="av t-vio"><?= ic('archive') ?></span><div class="grow"><div class="nm mono"><?= h($fn) ?></div><div class="mu"><?= h(fmt_bytes((float)$sn['size'])) ?></div></div>
              <button class="btn sm sec" type="button" data-open="dlg-rb-<?= md5($fn) ?>">Repor</button></div>
              <dialog id="dlg-rb-<?= md5($fn) ?>"><form method="post"><?= act_fields('update_rollback', ['file' => $fn]) ?>
                <div class="dlg-h"><h3>Repor <?= h($fn) ?></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
                <div class="dlg-b"><p style="margin:0">O painel e a configuração voltam ao estado dessa cópia. A conta de acesso (password e 2FA) não é alterada.</p><?= reauth_fields($auth) ?></div>
                <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn dan" type="submit">Repor</button></div>
              </form></dialog>
          <?php endforeach; ?>
        </div>
      </section>
      <?php endif; ?>

<?php endif; ?>
      <dialog id="dlg-reboot"><form method="post"><?= act_fields('reboot') ?>
        <div class="dlg-h"><h3>Reiniciar o servidor</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
        <div class="dlg-b"><p style="margin:0">O servidor reinicia dentro de 1 minuto. Os sites, o email e o painel ficam indisponíveis durante o arranque (normalmente 1 a 2 minutos).</p>
          <?= reauth_fields($auth) ?></div>
        <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn dan" type="submit">Reiniciar</button></div>
      </form></dialog>

<?php elseif ($page === 'logs'):
    $names = [];
    foreach ($sites as $s) { $sn0 = (string)($s['name'] ?? ''); if (valid_site($sn0)) $names[] = $sn0; }
    $lgSite = in_array(qget('site'), $names, true) ? qget('site') : ($names[0] ?? '');
    $lgT = in_array(qget('t'), ['access', 'error', 'php', 'slow', 'cron'], true) ? qget('t') : 'access';
    $lgDir = MP_SITE_LOGS . '/' . $lgSite;
    $lgSum = ($lgSite !== '' && $lgT === 'access') ? log_summary($lgDir . '/access.log') : null;
    $lgFiles = [];
    if ($lgSite !== '' && in_array($lgT, ['access', 'error', 'slow'], true)) {
        foreach ((array)glob($lgDir . '/' . ($lgT === 'slow' ? 'php-slow' : $lgT) . '.log*') as $lf) { if (is_file((string)$lf)) $lgFiles[] = ['n' => basename((string)$lf), 's' => (int)filesize((string)$lf), 'm' => (int)filemtime((string)$lf)]; }
        usort($lgFiles, function ($a, $b) { return $b['m'] <=> $a['m']; });
    }
    $crons = is_array($state['crons'] ?? null) ? array_values(array_filter($state['crons'], function ($c) use ($lgSite) { return ($c['site'] ?? '') === $lgSite; })) : [];
?>
<?php if (!$names): ?>
      <section class="card"><div class="empty"><b>Ainda não há sites</b>Os logs aparecem aqui depois de criares o primeiro site.</div></section>
<?php else: ?>
      <nav class="tabs" aria-label="Site">
        <select class="in" onchange="location.href='?p=logs&amp;t=<?= $lgT ?>&amp;site='+encodeURIComponent(this.value)" aria-label="Site" style="height:40px;min-width:200px;width:auto">
          <?php foreach ($names as $sn): ?><option value="<?= h($sn) ?>"<?= $sn === $lgSite ? ' selected' : '' ?>><?= h($sn) ?></option><?php endforeach; ?>
        </select>
        <?php foreach (['access' => 'Acessos', 'error' => 'Erros do servidor', 'php' => 'Erros do PHP', 'slow' => 'PHP lento', 'cron' => 'Tarefas agendadas'] as $tk => $tl): ?>
          <a class="chip<?= $lgT === $tk ? ' prim' : '' ?>" href="?p=logs&amp;site=<?= h(rawurlencode($lgSite)) ?>&amp;t=<?= $tk ?>"><?= $tl ?></a>
        <?php endforeach; ?>
        <label class="chk" style="margin-left:auto"><input type="checkbox" id="lg-live"> Ao vivo</label>
      </nav>

  <?php if ($lgSum !== null): ?>
      <section class="stats lg-stats">
        <div class="stat"><span class="tile t-blue"><?= ic('world') ?></span><div><div class="k">Pedidos (24 h)</div><div class="v"><?= number_format($lgSum['total'], 0, ',', ' ') ?> <small><?= h(fmt_bytes((float)$lgSum['bytes'])) ?> · <?= $lgSum['total'] ? round($lgSum['bots'] * 100 / $lgSum['total']) : 0 ?>% robôs</small></div></div></div>
        <div class="stat"><span class="tile t-acc"><?= ic('check') ?></span><div><div class="k">Sucesso (2xx / 3xx)</div><div class="v"><?= $lgSum['c']['2'] ?> <small>/ <?= $lgSum['c']['3'] ?></small></div></div></div>
        <div class="stat"><span class="tile t-warn"><?= ic('ban') ?></span><div><div class="k">Erros 4xx / 5xx</div><div class="v"><?= $lgSum['c']['4'] ?> <small>/ <b style="color:<?= $lgSum['c']['5'] > 0 ? 'var(--err)' : 'inherit' ?>"><?= $lgSum['c']['5'] ?></b></small></div></div></div>
        <div class="stat"><span class="tile t-vio"><?= ic('clock') ?></span><div><div class="k">Tempo médio (páginas)</div><div class="v"><?= $lgSum['rtn'] ? (int)round($lgSum['rts'] * 1000 / $lgSum['rtn']) . ' <small>ms</small>' : '—' ?></div></div></div>
        <?php $ch = $lgSum['cache']; $cht = array_sum($ch); if ($cht): ?><div class="stat"><span class="tile t-acc"><?= ic('pulse') ?></span><div><div class="k">Cache de página</div><div class="v"><?= (int)round(($ch['HIT'] ?? 0) * 100 / $cht) ?>% <small>da cache</small></div></div></div><?php endif; ?>
      </section>
      <div class="grid3 lg-grid">
        <?php foreach (['e5xx' => ['Erros 5xx (servidor/PHP)', 'Sem erros 5xx nas últimas 24 h.'], 'e404' => ['Páginas não encontradas (404)', 'Sem 404 nas últimas 24 h.']] as $k => $lbl): ?>
        <section class="card"><div class="card-h"><h2><?= $lbl[0] ?></h2></div>
          <?php if (!$lgSum[$k]): ?><div class="empty"><?= $lbl[1] ?></div><?php else: ?><div class="row-list">
          <?php foreach ($lgSum[$k] as $u => $cnt): ?><div class="item"><div class="grow mono lg-url" title="<?= h($u) ?>"><?= h($u) ?></div><b><?= (int)$cnt ?></b></div><?php endforeach; ?></div><?php endif; ?>
        </section>
        <?php endforeach; ?>
        <section class="card"><div class="card-h"><h2>Páginas mais lentas</h2></div>
          <?php if (!$lgSum['slow']): ?><div class="empty">Sem dados de tempo ainda (o registo de tempos começa com esta versão).</div><?php else: ?><div class="row-list">
          <?php foreach ($lgSum['slow'] as $u => $v): ?><div class="item"><div class="grow mono lg-url" title="<?= h($u) ?>"><?= h($u) ?></div><span class="mu"><?= (int)$v[0] ?>×</span><b style="<?= $v[1] / $v[0] >= 1 ? 'color:var(--err)' : '' ?>"><?= (int)round($v[1] * 1000 / $v[0]) ?> ms</b></div><?php endforeach; ?></div><?php endif; ?>
        </section>
        <section class="card"><div class="card-h"><h2>IPs mais ativos</h2></div>
          <?php if (!$lgSum['ips']): ?><div class="empty">Sem pedidos nas últimas 24 h.</div><?php else: ?><div class="row-list">
          <?php foreach ($lgSum['ips'] as $ip => $cnt): ?><div class="item"><div class="grow mono"><?= h($ip) ?></div><b><?= (int)$cnt ?></b>
            <form method="post" data-confirm="Bloquear <?= h($ip) ?> durante 24 horas?"><?= act_fields('fw_block', ['ip' => (string)$ip, 'dur' => '24h', 'reason' => 'Bloqueado a partir dos logs de ' . $lgSite]) ?><button class="btn sm sec lg-ban" type="submit" title="Bloquear durante 24 horas" aria-label="Bloquear"><?= ic('ban') ?></button></form></div><?php endforeach; ?></div><?php endif; ?>
        </section>
      </div>
  <?php endif; ?>

      <section class="card" id="lg" data-site="<?= h($lgSite) ?>" data-t="<?= $lgT ?>">
        <div class="card-h"><div><h2><?= ['access' => 'Acessos', 'error' => 'Erros do servidor (nginx)', 'php' => 'Erros do PHP', 'slow' => 'Scripts PHP lentos (ficheiro e função em curso)', 'cron' => 'Saída das tarefas agendadas'][$lgT] ?></h2><p class="mono"><?= h(['access' => MP_SITE_LOGS . "/$lgSite/access.log", 'error' => MP_SITE_LOGS . "/$lgSite/error.log", 'php' => "/srv/www/$lgSite/logs/php-error.log", 'slow' => MP_SITE_LOGS . "/$lgSite/php-slow.log (Sites → ⋮ → Desempenho)", 'cron' => "/srv/www/$lgSite/logs/cron-<id>.log"][$lgT]) ?></p></div>
          <div class="lg-filters">
            <?php if ($lgT === 'access'): ?>
            <select class="in" id="lg-st" aria-label="Código"><option value="">Todos os códigos</option><option value="2">2xx</option><option value="3">3xx</option><option value="4">4xx</option><option value="5">5xx</option></select>
            <input class="in mono" id="lg-ip" placeholder="IP" aria-label="IP">
            <?php elseif ($lgT === 'cron'): ?>
            <select class="in" id="lg-cron" aria-label="Tarefa"><?php foreach ($crons as $c): ?><option value="<?= h($c['id']) ?>"><?= h(($c['desc'] ?? '') !== '' ? $c['desc'] : $c['cmd']) ?></option><?php endforeach; ?><?php if (!$crons): ?><option value="">Sem tarefas</option><?php endif; ?></select>
            <?php endif; ?>
            <input class="in" id="lg-q" type="search" placeholder="Procurar texto…" aria-label="Procurar">
            <select class="in" id="lg-n" aria-label="Linhas"><option>200</option><option selected>500</option><option>2000</option></select>
          </div></div>
        <div id="lg-body"><div class="empty">A carregar…</div></div>
        <div class="card-f" style="display:flex;gap:10px;flex-wrap:wrap;align-items:center">
          <span class="mu" style="flex:1">Guardados durante <?= (int)($state['log_days'] ?? 90) ?> dias, rodados todos os dias e comprimidos.</span>
          <?php foreach (array_slice($lgFiles, 0, 8) as $lf): ?><a class="chip sm" href="?logs=dl&amp;site=<?= h(rawurlencode($lgSite)) ?>&amp;f=<?= h(rawurlencode($lf['n'])) ?>"><?= ic('download') ?><?= h($lf['n']) ?> <span class="mu"><?= h(fmt_bytes((float)$lf['s'])) ?></span></a><?php endforeach; ?>
          <?php if (count($lgFiles) > 8): ?><span class="mu">e mais <?= count($lgFiles) - 8 ?> ficheiros</span><?php endif; ?>
        </div>
      </section>
<?php endif; ?>

<?php elseif ($page === 'dns'):
    $dn = is_array($state['dns'] ?? null) ? $state['dns'] : ['enabled' => false];
    $dzs = (array)($dn['zones'] ?? []);
    $dzName = strtolower(qget('zone')); $dz = null;
    foreach ($dzs as $z0) { if ((string)$z0['name'] === $dzName) $dz = $z0; }
    $dtab = (qget('t') === 'servidor' || empty($dn['enabled'])) ? 'servidor' : 'dominios';
    $srvChk = jload(MP_STATS . '/dns-server.json') ?? [];
    $propAll = jload(MP_STATS . '/dns-prop.json') ?? [];
    $soa = is_array($dn['soa'] ?? null) ? $dn['soa'] : ['ttl' => 3600, 'refresh' => 10800, 'retry' => 3600, 'expire' => 1209600, 'minimum' => 3600];
    $ttlL = function ($t) use ($soa) { $t = (int)$t; if ($t <= 0) return 'Auto'; if ($t % 86400 === 0) return ($t / 86400) . ' d'; if ($t % 3600 === 0) return ($t / 3600) . ' h'; if ($t % 60 === 0) return ($t / 60) . ' min'; return $t . ' s'; };
    $zst = function ($z) { $ck = is_array($z['check'] ?? null) ? $z['check'] : null; return $ck === null ? ['p-off', 'Não verificado'] : (!empty($ck['delegated']) ? ['p-ok', 'Ativo'] : ['p-warn', 'Pendente: nameservers por mudar']); };
    $types = ['A', 'AAAA', 'CNAME', 'MX', 'TXT', 'SRV', 'CAA', 'NS'];
    $nsl = array_values(array_filter((array)($dn['ns_list'] ?? [(string)($dn['ns1'] ?? ''), (string)($dn['ns2'] ?? '')])));
    $nsTxt = implode(', ', array_map(function ($x) { return '<span class="mono">' . h((string)$x) . '</span>'; }, $nsl));
?>
      <?php if ($dz === null && !empty($dn['enabled'])): ?>
      <nav class="tabs" aria-label="Secções">
        <a class="chip<?= $dtab === 'dominios' ? ' prim' : '' ?>" href="?p=dns">Domínios <span class="sn-cnt"><?= count($dzs) ?></span></a>
        <a class="chip<?= $dtab === 'servidor' ? ' prim' : '' ?>" href="?p=dns&amp;t=servidor">Servidor DNS<?php $sf = count(array_filter((array)($srvChk['rows'] ?? []), function ($r) { return ($r['status'] ?? '') === 'fail'; })); if ($sf || empty($dn['active'])): ?> <span class="sn-b sn-b-f"><?= max($sf, 1) ?></span><?php endif; ?></a>
      </nav>
      <?php endif; ?>

<?php if ($dz !== null):   /* ===================== UM DOMÍNIO ===================== */
      $zn = (string)$dz['name']; [$zpc, $zpl] = $zst($dz); $ck = is_array($dz['check'] ?? null) ? $dz['check'] : null;
      $prop = []; foreach ((array)($propAll[$zn]['rows'] ?? []) as $pr) $prop[$pr['name'] . '|' . $pr['type']] = $pr;
      $recs = (array)$dz['records'];
      $tOrd = array_flip($types); usort($recs, function ($a, $b) use ($tOrd) { return [$tOrd[$a['type']] ?? 9, $a['name'] === '@' ? '' : $a['name'], (int)($a['prio'] ?? 0)] <=> [$tOrd[$b['type']] ?? 9, $b['name'] === '@' ? '' : $b['name'], (int)($b['prio'] ?? 0)]; });
      $full = function ($n) use ($zn) { return $n === '@' ? $zn : $n . '.' . $zn; };
?>
      <section class="card">
        <div class="card-h dz-h">
          <div><nav class="crumbs fm-pre"><a href="?p=dns"><?= ic('home') ?>Domínios</a><span>›</span><b><?= h($zn) ?></b></nav>
            <p style="margin-top:6px"><span class="pill <?= $zpc ?>"><?= h($zpl) ?></span> · <?= count($recs) + 2 ?> registos · última alteração <?= h(dns_serial_date((string)$dz['serial'])) ?></p></div>
          <div class="dz-act">
            <form method="post"><?= act_fields('dns_check', ['zone' => $zn]) ?><button class="btn sm sec" type="submit">Verificar nameservers</button></form>
            <form method="post"><?= act_fields('dns_propagation', ['zone' => $zn]) ?><button class="btn sm sec" type="submit">Verificar propagação</button></form>
            <details class="dd">
              <summary class="btn sm sec">Mais <?= ic('chev', 'chev') ?></summary>
              <div class="dd-menu">
                <div class="dd-lbl">Email do domínio</div>
                <form method="post" data-confirm="O email de <?= h($zn) ?> passa a ser recebido por este servidor (MX e SPF do painel). Continuar?"><?= act_fields('dns_template', ['zone' => $zn, 'tpl' => 'local']) ?><button type="submit"><?= ic('mail') ?>Este servidor</button></form>
                <form method="post" data-confirm="Substituir o MX e o SPF de <?= h($zn) ?> pelos da Google Workspace?"><?= act_fields('dns_template', ['zone' => $zn, 'tpl' => 'google']) ?><button type="submit"><?= ic('mail') ?>Google Workspace</button></form>
                <form method="post" data-confirm="Substituir o MX e o SPF de <?= h($zn) ?> pelos da Microsoft 365 (e criar o autodiscover)?"><?= act_fields('dns_template', ['zone' => $zn, 'tpl' => 'microsoft']) ?><button type="submit"><?= ic('mail') ?>Microsoft 365</button></form>
                <hr>
                <a href="?dnsexport=<?= h(rawurlencode($zn)) ?>"><?= ic('download') ?>Exportar zona (BIND)</a>
                <button type="button" data-open="dlg-dz-import"><?= ic('upload') ?>Importar zona (BIND)</button>
                <form method="post" data-confirm="Repor os registos predefinidos de <?= h($zn) ?>? Os registos do site e do email voltam aos valores do painel; os teus registos com outros nomes mantêm-se."><?= act_fields('dns_reset', ['zone' => $zn]) ?><button type="submit"><?= ic('reload') ?>Repor registos predefinidos</button></form>
                <hr>
                <form method="post" data-confirm="Apagar a zona <?= h($zn) ?>? Se o domínio usar este servidor DNS, deixa de funcionar."><?= act_fields('dns_zone_del', ['zone' => $zn]) ?><button type="submit" class="dan"><?= ic('trash') ?>Apagar domínio do DNS</button></form>
              </div>
            </details>
          </div>
        </div>
        <?php if ($ck !== null && !empty($ck['delegated'])): ?>
          <div class="dz-ban ok"><?= ic('check') ?> Este domínio usa este servidor DNS: as alterações têm efeito na Internet em poucos minutos.</div>
        <?php else: ?>
          <div class="dz-ban warn"><?= ic('bell') ?><div><b><?= $ck === null ? 'Ainda não verificado se o domínio usa este servidor.' : 'Este domínio ainda não usa este servidor DNS' . (!empty($ck['found']) ? ' (usa: ' . h(trim((string)$ck['found'])) . ')' : '') . '.' ?></b>
            No registador do domínio, muda os nameservers para:
            <?php foreach ($nsl as $nx): ?><span class="dz-ns"><code><?= h((string)$nx) ?></code><button type="button" class="chip sm" data-copy="<?= h((string)$nx) ?>">Copiar</button></span><?php endforeach; ?>
            Depois carrega em "Verificar nameservers".</div></div>
        <?php endif; ?>

        <?php if (!empty($dn['sec'])): ?><div class="dz-ban info"><?= ic('world') ?><div>DNS secundário ativo: este domínio tem de estar acrescentado no serviço<?= ($dn['sec']['provider'] ?? '') === 'he' ? ' (dns.he.net → Add a new slave)' : '' ?>. Os dados a preencher estão em <a href="?p=dns&amp;t=servidor">Servidor DNS → DNS secundário externo</a>.</div></div><?php endif; ?>
        <form method="post" class="dz-add" id="dz-add">
          <?= act_fields('dns_rec_add', ['zone' => $zn]) ?>
          <label class="fld">Tipo<select class="in" name="type" data-rtype><?php foreach (['A', 'AAAA', 'CNAME', 'MX', 'TXT', 'SRV', 'CAA', 'NS'] as $t): ?><option><?= $t ?></option><?php endforeach; ?></select></label>
          <label class="fld">Nome<div class="dz-name"><input class="in mono" name="name" placeholder="@ ou www" required autocomplete="off"><span class="mu">.<?= h($zn) ?></span></div></label>
          <label class="fld dz-val">Conteúdo<input class="in mono" name="value" required autocomplete="off" data-rval></label>
          <label class="fld dz-prio" hidden>Prioridade<input class="in" name="prio" value="10" inputmode="numeric"></label>
          <label class="fld">TTL<select class="in" name="ttl"><option value="0">Auto</option><option value="300">5 min</option><option value="1800">30 min</option><option value="3600">1 h</option><option value="86400">1 dia</option></select></label>
          <button class="btn" type="submit">Adicionar</button>
          <p class="mu dz-hint" data-rhint></p>
        </form>

        <div class="dz-filter">
          <select class="in" id="dz-ft"><option value="">Todos os tipos</option><?php foreach ($types as $t): ?><option><?= $t ?></option><?php endforeach; ?></select>
          <input class="in" id="dz-q" type="search" placeholder="Procurar nome ou conteúdo…">
          <?php if (!empty($propAll[$zn]['ts'])): ?><span class="mu" style="margin-left:auto">Propagação verificada <?= h(gmdate('d/m H:i', (int)$propAll[$zn]['ts'] + tz_off(live_stats()))) ?></span><?php endif; ?>
        </div>
        <table class="list dz-t">
          <colgroup><col style="width:90px"><col style="width:26%"><col><col style="width:90px"><col style="width:80px"><col style="width:120px"><col style="width:150px"></colgroup>
          <thead><tr><th>Tipo</th><th>Nome</th><th>Conteúdo</th><th>Prioridade</th><th>TTL</th><th>Propagação</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody id="dz-rows">
            <?php foreach ($nsl as $nsx): ?>
            <tr data-type="NS" data-s="<?= h($zn . ' ' . $nsx) ?>"><td><span class="pill p-off">NS</span></td><td class="mono"><?= h($zn) ?></td><td class="mono"><?= h($nsx) ?></td><td>—</td><td><?= h($ttlL(0)) ?></td><td>—</td><td class="r mu" title="Os nameservers vêm do Servidor DNS">🔒 Servidor</td></tr>
            <?php endforeach; ?>
            <?php foreach ($recs as $r): $k = $r['name'] . '|' . $r['type']; $pp = $prop[$k] ?? null; ?>
            <tr data-type="<?= h($r['type']) ?>" data-s="<?= h(strtolower($full($r['name']) . ' ' . $r['value'])) ?>">
              <td><span class="pill p-me"><?= h($r['type']) ?></span></td>
              <td><span class="mono"><?= h($full($r['name'])) ?></span><?= !empty($r['auto']) ? ' <span class="dz-auto" title="Criado pelo painel a partir dos sites e do email. Se o editares, passa a manual e o painel deixa de o alterar.">painel</span>' : '' ?></td>
              <td><div class="dnsval mono"><?= h((string)$r['value']) ?></div></td>
              <td><?= in_array($r['type'], ['MX', 'SRV'], true) ? (int)$r['prio'] : '—' ?></td>
              <td><?= h($ttlL($r['ttl'] ?? 0)) ?></td>
              <td><?= $pp === null ? '<span class="mu">—</span>' : (!empty($pp['ok']) ? '<span class="pill p-ok">Igual</span>' : '<span class="pill p-warn" title="' . h('Este servidor: ' . ($pp['local'] ?: 'nada') . ' · Internet (Google): ' . ($pp['public'] ?: 'nada')) . '">' . ($pp['public'] === '' ? 'Ainda não' : 'Diferente') . '</span>') ?></td>
              <td class="act r"><div class="dz-btns">
                <button class="btn sm sec" type="button" data-edit='<?= h((string)json_encode(['id' => $r['id'], 'name' => $r['name'], 'type' => $r['type'], 'value' => $r['value'], 'ttl' => (int)($r['ttl'] ?? 0), 'prio' => (int)($r['prio'] ?? 0)])) ?>'>Editar</button>
                <form method="post" data-confirm="Apagar o registo <?= h($r['type'] . ' ' . $full($r['name'])) ?>?<?= !empty($r['auto']) ? ' É um registo do painel: não volta a ser criado (usa Repor registos predefinidos para o recuperar).' : '' ?>"><?= act_fields('dns_rec_del', ['zone' => $zn, 'id' => (string)$r['id']]) ?><button class="btn sm sec" type="submit" aria-label="Apagar"><?= ic('trash') ?></button></form>
              </div></td>
            </tr>
            <?php endforeach; ?>
          </tbody>
        </table>
        <div class="card-f"><span class="mu" id="dz-cnt"></span></div>
      </section>

      <dialog class="drawer" id="dlg-dr-edit"><form method="post">
        <?= act_fields('dns_rec_edit', ['zone' => $zn]) ?><input type="hidden" name="id">
        <div class="dlg-h"><div><h3>Editar registo</h3><p class="mu" data-edit-note></p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
        <div class="dlg-b">
          <label class="fld">Tipo<select class="in" name="type" data-rtype><?php foreach (['A', 'AAAA', 'CNAME', 'MX', 'TXT', 'SRV', 'CAA', 'NS'] as $t): ?><option><?= $t ?></option><?php endforeach; ?></select></label>
          <label class="fld">Nome<div class="dz-name"><input class="in mono" name="name" required><span class="mu">.<?= h($zn) ?></span></div></label>
          <label class="fld">Conteúdo<textarea class="in mono" name="value" rows="3" required data-rval></textarea></label>
          <p class="mu dz-hint" data-rhint></p>
          <div class="fgrid">
            <label class="fld dz-prio">Prioridade<input class="in" name="prio" inputmode="numeric"></label>
            <label class="fld">TTL<select class="in" name="ttl"><option value="0">Auto</option><option value="300">5 min</option><option value="1800">30 min</option><option value="3600">1 h</option><option value="86400">1 dia</option></select></label>
          </div>
        </div>
        <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Guardar</button></div>
      </form></dialog>
      <dialog class="drawer" id="dlg-dz-import"><form method="post">
        <?= act_fields('dns_import', ['zone' => $zn]) ?>
        <div class="dlg-h"><div><h3>Importar zona</h3><p>Cola o conteúdo de um ficheiro de zona (formato BIND), por exemplo exportado do ISPmanager ou do Cloudflare.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
        <div class="dlg-b"><label class="fld">Ficheiro de zona<textarea class="in mono" name="zonetxt" rows="16" required placeholder="www  3600  IN  A  91.209.16.24&#10;@    3600  IN  MX 10 host.iddigital.pt."></textarea></label>
          <p class="mu">Os registos são acrescentados aos que já existem (os repetidos são ignorados). O SOA e os nameservers do domínio não são importados: vêm deste servidor.</p></div>
        <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Importar</button></div>
      </form></dialog>

<?php elseif ($dtab === 'dominios'):   /* ===================== LISTA DE DOMÍNIOS ===================== */ ?>
      <section class="card">
        <div class="card-h"><div><h2>Domínios</h2><p>Cada domínio tem a sua zona de DNS neste servidor. Os registos dos sites e do email são criados sozinhos.</p></div><button class="btn sm" type="button" data-open="dlg-dz-new"><?= ic('plus') ?>Adicionar domínio</button></div>
        <?php if (!$dzs): ?><div class="empty"><b>Ainda não há domínios</b>Adiciona o primeiro domínio. Depois, no registador, aponta os nameservers para <?= $nsTxt ?>.</div>
        <?php else: [$zl, $zpg, $zpages, $ztot] = paginate($dzs, 50); ?>
        <table class="list">
          <colgroup><col><col style="width:260px"><col style="width:110px"><col style="width:160px"><col style="width:140px"></colgroup>
          <thead><tr><th>Domínio</th><th>Estado</th><th class="r">Registos</th><th>Última alteração</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody><?php foreach ($zl as $z): [$pc, $pl] = $zst($z); ?>
            <tr><td><a class="who" href="?p=dns&amp;zone=<?= h(rawurlencode((string)$z['name'])) ?>" style="text-decoration:none;color:inherit"><span class="av <?= tone((string)$z['name']) ?>"><?= ic('world') ?></span><span class="nm"><?= h((string)$z['name']) ?></span></a></td>
              <td><span class="pill <?= $pc ?>"><?= h($pl) ?></span></td><td class="r"><?= count((array)$z['records']) + 2 ?></td><td><?= h(dns_serial_date((string)$z['serial'])) ?></td>
              <td class="r"><a class="btn sm sec" href="?p=dns&amp;zone=<?= h(rawurlencode((string)$z['name'])) ?>">Gerir DNS</a></td></tr>
          <?php endforeach; ?></tbody>
        </table>
        <?php if ($zpages > 1): ?><div class="card-f"><?= pager($zpg, $zpages, $ztot, 'pg', 'domínios') ?></div><?php endif; ?>
        <?php endif; ?>
      </section>
      <dialog class="drawer" id="dlg-dz-new"><form method="post">
        <?= act_fields('dns_zone_add') ?>
        <div class="dlg-h"><div><h3>Adicionar domínio</h3><p>Cria a zona com os registos do site e do email já preenchidos.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
        <div class="dlg-b"><label class="fld">Domínio<input class="in mono" name="zone" required placeholder="exemplo.pt" autocomplete="off"></label>
          <p class="mu">Depois, no registador do domínio, aponta os nameservers para <?= $nsTxt ?>. Nos domínios <span class="mono">.pt</span>, cria a zona aqui <b>antes</b> de mudar no registador.</p></div>
        <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Adicionar</button></div>
      </form></dialog>

<?php else:   /* ===================== SERVIDOR DNS ===================== */ ?>
      <?php if (empty($dn['enabled'])): ?>
      <section class="card">
        <div class="card-h"><div><h2>Ativar o servidor DNS</h2><p>O servidor passa a responder pelo DNS dos teus domínios (NSD, só autoritativo: nunca faz resolução para terceiros).</p></div></div>
        <form method="post" class="card-b"><?= act_fields('dns_enable') ?>
          <div class="fgrid">
            <label class="fld">Nameserver 1<input class="in mono" name="ns1" required placeholder="ns1.host.iddigital.pt"></label>
            <label class="fld">Nameserver 2<input class="in mono" name="ns2" required placeholder="ns2.host.iddigital.pt"></label>
            <label class="fld">IP público (IPv4)<input class="in mono" name="ip" placeholder="automático"></label>
            <label class="fld">Email do responsável<input class="in" name="hm" type="email" placeholder="dns@iddigital.pt"></label>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Ativar</button></div>
        </form>
      </section>
      <?php else: $rows = (array)($srvChk['rows'] ?? []); ?>
      <section class="card">
        <div class="card-h"><div><h2>Estado do servidor DNS</h2><p><span class="pill <?= !empty($dn['active']) ? 'p-ok' : 'p-err' ?>"><?= !empty($dn['active']) ? 'A correr' : 'Parado' ?></span> · <?= count($dzs) ?> domínios<?= !empty($srvChk['ts']) ? ' · verificado ' . h(gmdate('d/m H:i', (int)$srvChk['ts'] + tz_off(live_stats()))) : '' ?></p></div>
          <div class="dz-act">
            <form method="post"><?= act_fields('dns_server_check') ?><button class="btn sm" type="submit">Verificar agora</button></form>
            <form method="post" data-confirm="Reiniciar o servidor DNS? Fica alguns segundos sem responder."><?= act_fields('dns_restart') ?><button class="btn sm sec" type="submit">Reiniciar</button></form>
          </div></div>
        <?php if (!$rows): ?><div class="empty">Carrega em "Verificar agora" para testar o servidor DNS.</div>
        <?php else: ?>
        <table class="list sn-t"><colgroup><col style="width:110px"><col style="width:300px"><col></colgroup>
          <thead><tr><th>Estado</th><th>Teste</th><th>Resultado</th></tr></thead>
          <tbody><?php foreach ($rows as $r): ?><tr><td><?= ($r['status'] ?? '') === 'ok' ? '<span class="pill p-ok">OK</span>' : (($r['status'] ?? '') === 'warn' ? '<span class="pill p-warn">Aviso</span>' : '<span class="pill p-err">Falha</span>') ?></td><td><b><?= h((string)$r['name']) ?></b></td><td class="sn-msg"><?= h((string)$r['msg']) ?></td></tr><?php endforeach; ?></tbody>
        </table>
        <?php endif; ?>
      </section>
      <?php $sec = is_array($dn['sec'] ?? null) ? $dn['sec'] : null; $isHe = $sec && ($sec['provider'] ?? '') === 'he'; ?>
      <section class="card">
        <div class="card-h"><div><h2>DNS secundário externo</h2><p>Um serviço externo copia as zonas deste servidor e responde por elas noutros IPs. O DNS.PT exige nameservers com IPs diferentes, e se este servidor parar os domínios continuam a resolver.</p></div>
          <span class="pill <?= $sec ? 'p-ok' : 'p-off' ?>"><?= $sec ? 'Ativo' . ($isHe ? ' · Hurricane Electric' : '') : 'Desligado' ?></span></div>
        <?php if ($sec): ?>
        <div class="card-b">
          <p style="margin:0 0 10px"><b><?= $isHe ? 'Em dns.he.net → "Add a new slave", para cada domínio:' : 'No serviço secundário, para cada domínio:' ?></b></p>
          <table class="list sec-t"><colgroup><col style="width:200px"><col><col style="width:110px"></colgroup><tbody>
            <tr><td class="mu"><?= $isHe ? 'Domain Name' : 'Domínio' ?></td><td>o domínio (ex.: <span class="mono">pontoderede.pt</span>)</td><td></td></tr>
            <tr><td class="mu"><?= $isHe ? 'Master #1' : 'Servidor principal' ?></td><td class="mono"><?= h((string)$dn['ip']) ?></td><td><button type="button" class="chip sm" data-copy="<?= h((string)$dn['ip']) ?>">Copiar</button></td></tr>
            <?php if (!empty($sec['tsig'])): ?>
            <tr><td class="mu"><?= $isHe ? 'Hash Algorithm' : 'Algoritmo TSIG' ?></td><td class="mono">hmac-sha256</td><td></td></tr>
            <tr><td class="mu"><?= $isHe ? 'Key Name' : 'Nome da chave' ?></td><td class="mono"><?= h((string)$sec['keyname']) ?></td><td><button type="button" class="chip sm" data-copy="<?= h((string)$sec['keyname']) ?>">Copiar</button></td></tr>
            <tr><td class="mu"><?= $isHe ? 'Secret Hash' : 'Segredo' ?></td><td class="mono sec-key"><?= h((string)$sec['key']) ?></td><td><button type="button" class="chip sm" data-copy="<?= h((string)$sec['key']) ?>">Copiar</button></td></tr>
            <?php else: ?><tr><td class="mu">TSIG</td><td>Sem chave (cópia autorizada só pelo IP)</td><td></td></tr><?php endif; ?>
          </tbody></table>
          <p style="margin:16px 0 6px"><b>No registador de cada domínio, os nameservers ficam:</b></p>
          <div class="sec-ns"><?php foreach ((array)($dn['ns_list'] ?? []) as $nx): ?><span class="dz-ns"><code><?= h((string)$nx) ?></code><button type="button" class="chip sm" data-copy="<?= h((string)$nx) ?>">Copiar</button></span><?php endforeach; ?></div>
          <p class="mu" style="margin:12px 0 0">Depois de acrescentares um domínio no serviço, carrega em "Verificar agora" (acima): o teste "DNS secundário" confirma, zona a zona, que a cópia está em dia.<?= $isHe ? ' <a href="https://dns.he.net/" target="_blank" rel="noopener">Abrir dns.he.net</a>' : '' ?></p>
        </div>
        <div class="card-f" style="display:flex;gap:8px;flex-wrap:wrap">
          <form method="post" data-confirm="Gerar uma chave nova? A cópia deixa de funcionar até atualizares o Key Name/Secret Hash no serviço, em todos os domínios."><?= act_fields('dns_secondary', ['op' => 'newkey']) ?><button class="btn sm sec" type="submit">Gerar chave nova</button></form>
          <form method="post" data-confirm="Desligar o DNS secundário? Os domínios cujos nameservers incluem o serviço deixam de ser atualizados lá."><?= act_fields('dns_secondary', ['op' => 'off']) ?><button class="btn sm sec" type="submit">Desligar</button></form>
        </div>
        <?php endif; ?>
        <form method="post" class="card-b sec-f"<?= $sec ? ' style="border-top:1px solid var(--line)"' : '' ?>>
          <?= act_fields('dns_secondary', ['op' => 'save']) ?>
          <div class="fgrid">
            <label class="fld">Serviço<select class="in" name="provider" data-secprov>
              <option value="he"<?= !$sec || $isHe ? ' selected' : '' ?>>Hurricane Electric (gratuito, recomendado)</option>
              <option value="custom"<?= $sec && !$isHe ? ' selected' : '' ?>>Outro serviço</option></select></label>
            <label class="fld" data-seccustom>IPs que copiam as zonas<input class="in mono" name="ips" value="<?= h($sec && !$isHe ? implode(' ', (array)$sec['ips']) : '') ?>" placeholder="ex.: 203.0.113.10 2001:db8::10"></label>
            <label class="fld" data-seccustom>Nameservers do serviço<input class="in mono" name="ns" value="<?= h($sec && !$isHe ? implode(' ', (array)$sec['ns']) : '') ?>" placeholder="ex.: ns2.servico.net ns3.servico.net"></label>
          </div>
          <label class="chk" style="margin-top:12px"><input type="checkbox" name="tsig" value="1"<?= !$sec || !empty($sec['tsig']) ? ' checked' : '' ?>> Proteger a cópia com chave TSIG (recomendado)</label>
          <label class="chk"><input type="checkbox" name="keep_ns2" value="1"<?= $sec && !empty($sec['keep_ns2']) ? ' checked' : '' ?>> Manter também o <?= h((string)$dn['ns2']) ?> (só se tiver um IP diferente do <?= h((string)$dn['ns1']) ?>)</label>
          <div style="margin-top:14px"><button class="btn" type="submit"><?= $sec ? 'Guardar' : 'Ativar o DNS secundário' ?></button></div>
        </form>
      </section>
      <div class="grid2e" style="align-items:stretch">
        <section class="card">
          <div class="card-h"><div><h2>Nameservers</h2><p>Os nomes com que a Internet chega a este servidor DNS. Na zona do domínio-mãe (ex.: <span class="mono"><?= h(preg_replace('/^[^.]+\.[^.]+\./', '', (string)$dn['ns1'])) ?></span>) têm de existir os registos A destes nomes com o IP abaixo.</p></div></div>
          <form method="post" class="card-b" data-confirm="Guardar os nameservers? Todas as zonas são atualizadas."><?= act_fields('dns_enable') ?>
            <div class="fgrid">
              <label class="fld">Nameserver 1<input class="in mono" name="ns1" required value="<?= h((string)$dn['ns1']) ?>"></label>
              <label class="fld">Nameserver 2<input class="in mono" name="ns2" required value="<?= h((string)$dn['ns2']) ?>"></label>
              <label class="fld">IP público (IPv4)<input class="in mono" name="ip" required value="<?= h((string)$dn['ip']) ?>"></label>
              <label class="fld">IPv6 (opcional)<input class="in mono" name="ip6" value="<?= h((string)($dn['ip6'] ?? '')) ?>"></label>
              <label class="fld">Email do responsável<input class="in" name="hm" type="email" value="<?= h((string)($dn['hostmaster'] ?? '')) ?>"></label>
            </div>
            <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
          </form>
        </section>
        <section class="card">
          <div class="card-h"><div><h2>Valores predefinidos</h2><p>TTL "Auto" dos registos e tempos do SOA de todas as zonas. Os valores atuais servem para quase todos os casos.</p></div></div>
          <form method="post" class="card-b"><?= act_fields('dns_settings') ?>
            <div class="fgrid">
              <label class="fld">TTL predefinido (s)<input class="in" name="ttl" inputmode="numeric" value="<?= (int)$soa['ttl'] ?>"><small>Quanto tempo a Internet guarda as respostas (3600 = 1 h)</small></label>
              <label class="fld">Refresh (s)<input class="in" name="refresh" inputmode="numeric" value="<?= (int)$soa['refresh'] ?>"></label>
              <label class="fld">Retry (s)<input class="in" name="retry" inputmode="numeric" value="<?= (int)$soa['retry'] ?>"></label>
              <label class="fld">Expire (s)<input class="in" name="expire" inputmode="numeric" value="<?= (int)$soa['expire'] ?>"></label>
              <label class="fld">TTL negativo (s)<input class="in" name="minimum" inputmode="numeric" value="<?= (int)$soa['minimum'] ?>"><small>Quanto tempo se lembra de que um nome não existe</small></label>
            </div>
            <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
          </form>
        </section>
      </div>
      <?php endif; ?>
<?php endif; ?>

<?php elseif ($page === 'terminal'):
    $tOn = !empty($auth['totp']);
    $tSes = (is_array($_SESSION['term'] ?? null) && time() - (int)$_SESSION['term']['ts'] < 14400) ? (string)$_SESSION['term']['t'] : '';
    $recs = [];
    foreach ((array)glob(MP_TERM_LOG . '/*.log') as $rf) {
        $rid = basename((string)$rf, '.log'); if (!preg_match('/^\d{8}-\d{6}$/', $rid)) continue;
        $recs[] = ['id' => $rid, 's' => (int)@filesize((string)$rf), 'm' => (int)@filemtime((string)$rf)];
    }
    usort($recs, function ($a, $b) { return strcmp($b['id'], $a['id']); });
    $tz = tz_off(live_stats());
?>
<?php if (!$tOn): ?>
      <section class="card"><div class="empty"><b>O terminal exige a verificação em dois passos</b>Por segurança, o terminal (root) só fica disponível com o 2FA ativo.<br><a class="btn" href="?p=conta&amp;tfa=setup">Ativar a verificação em dois passos</a></div></section>
<?php elseif ($tSes === ''): ?>
      <section class="card">
        <div class="card-h"><div><h2>Abrir terminal</h2><p>Terminal do servidor como <b>root</b>, no browser. A sessão é gravada e fecha ao fim de 15 minutos sem atividade.</p></div></div>
        <form method="post" class="card-b">
          <?= act_fields('terminal_open') ?>
          <div class="fgrid"><?= reauth_fields($auth) ?></div>
          <div style="margin-top:16px"><button class="btn" type="submit"><?= ic('code') ?>Abrir terminal</button></div>
        </form>
        <div class="card-f mu">Tudo o que aparecer no ecrã fica gravado durante 90 dias (as passwords escritas não aparecem no ecrã e por isso não ficam gravadas). A abertura fica também no registo de auditoria.</div>
      </section>
<?php else: ?>
      <section class="card term-card">
        <div class="card-h"><div><h2>Terminal (root)</h2><p>Sessão gravada · fecha com <span class="mono">exit</span> ou ao fim de 15 min sem atividade</p></div>
          <form method="post"><?= act_fields('terminal_close') ?><button class="btn sm dan" type="submit">Fechar terminal</button></form></div>
        <div class="term-wrap"><div class="term-wait" id="term-wait"><span class="spin"></span> A iniciar o terminal…</div><iframe id="term" title="Terminal" data-src="/terminal/<?= h($tSes) ?>/"></iframe></div>
      </section>
<?php endif; ?>
      <section class="card">
        <div class="card-h"><div><h2>Sessões gravadas</h2><p>Guardadas durante 90 dias em <span class="mono"><?= h(MP_TERM_LOG) ?></span>. O ficheiro de tempos permite rever a sessão com <span class="mono">scriptreplay</span>.</p></div></div>
        <?php if (!$recs): ?><div class="empty">Ainda não há sessões gravadas.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Início</th><th class="r">Tamanho</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach (array_slice($recs, 0, 100) as $r): $dt = DateTime::createFromFormat('Ymd-His', $r['id'], new DateTimeZone('UTC')); ?>
            <tr><td class="first mono" data-label="Início"><?= h($dt ? gmdate('d/m/Y H:i:s', $dt->getTimestamp() + $tz) : $r['id']) ?></td><td class="r" data-label="Tamanho"><?= h(fmt_bytes((float)$r['s'])) ?></td>
              <td class="act r"><a class="btn sm sec" href="?term=view&amp;id=<?= h($r['id']) ?>" target="_blank" rel="noopener">Ver</a> <a class="btn sm sec" href="?term=dl&amp;id=<?= h($r['id']) ?>">Descarregar</a> <a class="btn sm sec" href="?term=dl&amp;f=timing&amp;id=<?= h($r['id']) ?>" title="Para rever com: scriptreplay -t sessão.timing sessão.log">Tempos</a></td></tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
      </section>

<?php elseif ($page === 'alertas'):
    $al = is_array($state['alerts'] ?? null) ? $state['alerts'] : [];
    $atab = in_array(qget('t'), ['config', 'historico', 'email'], true) ? qget('t') : 'config';
    $tza = tz_off(live_stats());
?>
      <nav class="tabs" aria-label="Secções">
        <?php foreach (['config' => 'Configuração', 'historico' => 'Histórico', 'email' => 'Volume de email'] as $tk => $tl): ?>
          <a class="chip<?= $atab === $tk ? ' prim' : '' ?>" href="?p=alertas&amp;t=<?= $tk ?>"><?= $tl ?></a>
        <?php endforeach; ?>
      </nav>
  <?php if ($atab === 'config'): ?>
      <form method="post">
      <?= act_fields('alerts_settings') ?>
      <div class="grid2e" style="align-items:stretch">
        <section class="card">
          <div class="card-h"><div><h2>SMS (bulksms.com)</h2><p>Credenciais em bulksms.com → Settings → API Tokens. Um alerta por problema, um aviso quando volta ao normal e um lembrete a cada 6 horas se continuar.</p></div><span class="pill <?= !empty($al['sms_on']) ? 'p-ok' : 'p-off' ?>"><?= !empty($al['sms_on']) ? 'Ativo' : 'Desligado' ?></span></div>
          <div class="card-b">
            <div class="fgrid">
              <label class="fld">Estado<select class="in" name="sms"><option value="on"<?= !empty($al['sms_on']) ? ' selected' : '' ?>>Ativo</option><option value="off"<?= empty($al['sms_on']) ? ' selected' : '' ?>>Desligado</option></select></label>
              <label class="fld">Números<input class="in mono" name="sms_to" value="<?= h((string)($al['sms_to'] ?? '')) ?>" placeholder="+351912345678"><small>Formato internacional; vários separados por vírgulas</small></label>
              <label class="fld">Token ID<input class="in mono" name="sms_id" value="<?= h((string)($al['sms_id'] ?? '')) ?>" autocomplete="off"></label>
              <label class="fld">Token secreto<input class="in mono" type="password" name="sms_secret" autocomplete="new-password" placeholder="<?= !empty($al['sms_secret']) ? '•••••••• (guardado)' : '' ?>"><small><?= !empty($al['sms_secret']) ? 'Vazio = manter o atual' : 'Fica guardado só no servidor' ?></small></label>
            </div>
          </div>
        </section>
        <section class="card" style="display:flex;flex-direction:column">
          <div class="card-h"><div><h2>Email</h2><p>Enviado pelo servidor de email deste servidor<?= empty($al['mail_on']) ? ' (o email não está ativo: ativa-o na página Email para usar este canal)' : '' ?>.</p></div><span class="pill <?= !empty($al['email_on']) && !empty($al['mail_on']) ? 'p-ok' : 'p-off' ?>"><?= !empty($al['email_on']) && !empty($al['mail_on']) ? 'Ativo' : 'Desligado' ?></span></div>
          <div class="card-b">
            <div class="fgrid">
              <label class="fld">Estado<select class="in" name="email"><option value="on"<?= !empty($al['email_on']) ? ' selected' : '' ?>>Ativo</option><option value="off"<?= empty($al['email_on']) ? ' selected' : '' ?>>Desligado</option></select></label>
              <label class="fld">Enviar para<input class="in" type="email" name="email_to" value="<?= h((string)($al['email_to'] ?? '')) ?>" placeholder="alertas@iddigital.pt"></label>
            </div>
          </div>
          <div class="card-f" style="display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-top:auto"><span class="grow mu">Depois de guardar, confirma que as mensagens chegam (SMS e email).</span><button class="btn sm sec" type="submit" form="al-test">Enviar mensagem de teste</button></div>
        </section>
      </div>
      <section class="card">
        <div class="card-h"><div><h2>Limites</h2><p>Quando um limite é ultrapassado é enviado um alerta pelos canais ativos.</p></div></div>
        <div class="card-b">
          <div class="fgrid" style="grid-template-columns:repeat(4,minmax(0,1fr))">
            <label class="fld">CPU (%)<input class="in" name="cpu" inputmode="numeric" value="<?= (int)($al['cpu'] ?? 90) ?>"></label>
            <label class="fld">Durante (minutos)<input class="in" name="cpu_min" inputmode="numeric" value="<?= (int)($al['cpu_min'] ?? 5) ?>"></label>
            <label class="fld">RAM (%, durante 5 min)<input class="in" name="ram" inputmode="numeric" value="<?= (int)($al['ram'] ?? 90) ?>"></label>
            <label class="fld">Disco (%)<input class="in" name="disk" inputmode="numeric" value="<?= (int)($al['disk'] ?? 90) ?>"></label>
            <label class="fld">Ligações (% da capacidade)<input class="in" name="conn" inputmode="numeric" value="<?= (int)($al['conn'] ?? 70) ?>"></label>
            <label class="fld">Email acima do normal (%)<input class="in" name="mail_pct" inputmode="numeric" value="<?= (int)($al['mail_pct'] ?? 20) ?>"></label>
            <label class="fld">Mínimo (mensagens/hora)<input class="in" name="mail_min" inputmode="numeric" value="<?= (int)($al['mail_min'] ?? 50) ?>"><small>Evita alertas com volumes pequenos</small></label>
            <div class="fld" style="justify-content:flex-end"><span class="mu">O modo de proteção de ligações envia sempre alerta ao ativar e desativar.</span></div>
          </div>
          <div style="display:flex;gap:10px;margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </div>
      </section>
      </form>
      <form method="post" id="al-test" hidden><?= act_fields('alerts_test') ?></form>

  <?php elseif ($atab === 'historico'):
      $hist = [];
      foreach (array_reverse(log_tail(MP_STATS . '/alerts.log', 2000)) as $ln) { $j = json_decode($ln, true); if (is_array($j)) $hist[] = $j; }
      [$hl, $hpg, $hpages, $htot] = paginate($hist, 50);
      $chan = function (string $v): string { return $v === 'ok' ? '<span class="pill p-ok">Enviado</span>' : ($v === 'falhou' ? '<span class="pill p-err">Falhou</span>' : '<span class="mu">—</span>'); };
  ?>
      <section class="card">
        <div class="card-h"><div><h2>Histórico de alertas</h2><p>Últimos 2000 alertas.</p></div></div>
        <?php if (!$hist): ?><div class="empty">Ainda não houve alertas.</div><?php else: ?>
        <table class="list cards">
          <thead><tr><th>Data</th><th>Alerta</th><th>SMS</th><th>Email</th></tr></thead>
          <tbody><?php foreach ($hl as $a): ?>
            <tr><td class="first mono" data-label="Data"><?= h(gmdate('d/m/Y H:i', (int)$a['ts'] + $tza)) ?></td>
              <td data-label="Alerta"><span class="pill <?= ($a['level'] ?? '') === 'crit' ? 'p-err' : (($a['level'] ?? '') === 'ok' ? 'p-ok' : 'p-warn') ?>" style="margin-right:6px"><?= ($a['level'] ?? '') === 'crit' ? 'Alerta' : (($a['level'] ?? '') === 'ok' ? 'Resolvido' : 'Aviso') ?></span><?= h((string)($a['msg'] ?? '')) ?></td>
              <td data-label="SMS"><?= $chan((string)($a['sms'] ?? '')) ?></td><td data-label="Email"><?= $chan((string)($a['email'] ?? '')) ?></td></tr>
          <?php endforeach; ?></tbody>
        </table>
        <div class="card-f"><?= pager($hpg, $hpages, $htot, 'pg', 'alertas') ?></div>
        <?php endif; ?>
      </section>

  <?php else:
      $rows = [];
      foreach (log_tail(MP_STATS . '/mail-vol.csv', 1500) as $ln) { $p = explode(',', $ln); if (count($p) === 3 && ctype_digit($p[0])) $rows[] = [(int)$p[0], (int)$p[1], (int)$p[2]]; }
      $first = (int)($al['learn_start'] ?? 0); $days = (int)($al['learn_days'] ?? 0); $ready = $first > 0 && $days >= 30;
      $norm = [];
      foreach ($rows as $r) { if ($r[0] < time() - 30 * 86400) continue; $hd = intdiv($r[0] % 86400, 3600); $norm[$hd][0] = ($norm[$hd][0] ?? 0) + $r[1]; $norm[$hd][1] = ($norm[$hd][1] ?? 0) + $r[2]; $norm[$hd][2] = ($norm[$hd][2] ?? 0) + 1; }
      $last = array_slice(array_reverse($rows), 0, 24);
  ?>
      <section class="card">
        <div class="card-h"><div><h2>Aprendizagem do volume de email</h2><p>Durante 30 dias o servidor só regista o email que entra e sai, hora a hora, para saber o que é normal. Depois disso, cada hora acima do normal em mais de <?= (int)($al['mail_pct'] ?? 20) ?>% (e com pelo menos <?= (int)($al['mail_min'] ?? 50) ?> mensagens a mais) dispara um alerta por SMS e email.</p></div>
          <span class="pill <?= $ready ? 'p-ok' : 'p-warn' ?>"><?= $ready ? 'A vigiar' : ($first ? 'A aprender: dia ' . min(30, $days + 1) . ' de 30' : 'À espera do primeiro registo') ?></span></div>
        <?php if (!$ready): ?><div class="card-b"><div class="cbar" style="height:10px"><span style="width:<?= (int)min(100, $days * 100 / 30) ?>%"></span></div><p class="mu" style="margin:8px 0 0"><?= empty($al['mail_on']) ? 'O email deste servidor não está ativo; o registo começa quando for ativado.' : 'Faltam ' . max(0, 30 - $days) . ' dias para os alertas de volume ficarem ativos.' ?></p></div><?php endif; ?>
        <?php if ($last): ?>
        <table class="list cards">
          <thead><tr><th>Hora</th><th class="r">Recebidos</th><th class="r">Normal</th><th class="r">Enviados</th><th class="r">Normal</th></tr></thead>
          <tbody><?php foreach ($last as $r): $hd = intdiv($r[0] % 86400, 3600); $n = $norm[$hd] ?? [0, 0, 1]; $ni = $n[0] / max(1, $n[2]); $no = $n[1] / max(1, $n[2]);
            $hiI = $ready && $r[1] > $ni * (1 + ($al['mail_pct'] ?? 20) / 100) && $r[1] - $ni >= ($al['mail_min'] ?? 50); $hiO = $ready && $r[2] > $no * (1 + ($al['mail_pct'] ?? 20) / 100) && $r[2] - $no >= ($al['mail_min'] ?? 50); ?>
            <tr><td class="first mono" data-label="Hora"><?= h(gmdate('d/m H:00', $r[0] + $tza)) ?></td>
              <td class="r" data-label="Recebidos"><b style="<?= $hiI ? 'color:var(--err)' : '' ?>"><?= $r[1] ?></b></td><td class="r mu" data-label="Normal"><?= $ready ? (int)round($ni) : '—' ?></td>
              <td class="r" data-label="Enviados"><b style="<?= $hiO ? 'color:var(--err)' : '' ?>"><?= $r[2] ?></b></td><td class="r mu" data-label="Normal"><?= $ready ? (int)round($no) : '—' ?></td></tr>
          <?php endforeach; ?></tbody>
        </table>
        <?php endif; ?>
      </section>
  <?php endif; ?>

<?php elseif ($page === 'processos'): ?>
      <section class="card">
        <div class="card-h"><div><h2>Quem está a consumir recursos</h2><p>CPU e memória por origem: cada site, email, base de dados, servidor web, painel e sistema. Atualiza a cada 10 segundos.</p></div></div>
        <div id="pr-sum" class="pr-sum"><div class="empty">A carregar…</div></div>
      </section>
      <section class="card" id="pr">
        <div class="card-h"><div><h2>Processos</h2><p>CPU atual (100% = um núcleo inteiro). Os processos essenciais do servidor e do painel não podem ser terminados aqui.</p></div>
          <div class="lg-filters">
            <select class="in" id="pr-f" aria-label="Origem"><option value="">Todas as origens</option><option value="site">Sites</option><option value="email">Email</option><option value="bd">Base de dados</option><option value="web">Servidor web</option><option value="painel">Painel</option><option value="sistema">Sistema</option></select>
            <input class="in" id="pr-q" type="search" placeholder="Procurar…" title="Comando, utilizador, PID ou site" aria-label="Procurar" style="min-width:220px">
          </div></div>
        <table class="list cards">
          <thead><tr><th>PID</th><th>Origem</th><th class="r">CPU</th><th class="r">Memória</th><th>Há</th><th>Comando</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody id="pr-rows"><tr><td colspan="7" class="empty">A carregar…</td></tr></tbody>
        </table>
        <div class="card-f" style="display:flex;align-items:center;gap:12px;flex-wrap:wrap"><span class="mu" id="pr-foot" style="flex:1"></span><nav class="pager" id="pr-pager"></nav></div>
      </section>
      <dialog id="dlg-kill"><form method="post"><?= act_fields('proc_kill') ?><input type="hidden" name="pid" id="kill-pid">
        <div class="dlg-h"><h3>Terminar processo <span id="kill-t" class="mono"></span></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
        <div class="dlg-b"><p class="mono" id="kill-cmd" style="margin:0;word-break:break-all"></p>
          <label class="chk"><input type="checkbox" name="force" value="1"> Forçar (SIGKILL: termina de imediato, sem deixar o processo arrumar; usa só se não terminar normalmente)</label>
          <div id="kill-site"></div></div>
        <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn dan" type="submit">Terminar</button></div>
      </form></dialog>
      <form method="post" id="kill-site-f" style="display:none" data-confirm=""><?= act_fields('proc_kill_site') ?><input type="hidden" name="site" id="kill-site-n"></form>

<?php elseif ($page === 'sentinela'):
    $sn = jload(MP_STATS . '/sentinel.json') ?? [];
    $snR = is_array($sn['results'] ?? null) ? $sn['results'] : [];
    $snst = jload(MP_STATS . '/sentinel-state.json') ?? [];
    $stab = in_array(qget('t'), ['estado', 'incidentes', 'disponibilidade', 'config'], true) ? qget('t') : 'estado';
    $tzs = tz_off(live_stats());
    $cnt = ['ok' => 0, 'warn' => 0, 'fail' => 0]; foreach ($snR as $r) $cnt[$r['status']] = ($cnt[$r['status']] ?? 0) + 1;
    $snAge = time() - (int)($sn['ts'] ?? 0);
    $snOff = (string)($state['sentinel']['off'] ?? '');
?>
      <nav class="tabs" aria-label="Secções">
        <?php foreach (['estado' => 'Estado', 'incidentes' => 'Incidentes', 'disponibilidade' => 'Disponibilidade', 'config' => 'Configuração'] as $tk => $tl): ?><a class="chip<?= $stab === $tk ? ' prim' : '' ?>" href="?p=sentinela&amp;t=<?= $tk ?>"><?= $tl ?></a><?php endforeach; ?>
        <form method="post" style="margin-left:auto"><?= act_fields('sentinel_run') ?><button class="btn sm sec" type="submit"><?= ic('reload') ?>Testar agora</button></form>
      </nav>
<?php if ($stab === 'estado'):
      $order = ['Serviços', 'Sites', 'Email', 'DNS', 'Certificados', 'Sistema', 'Painel'];
      $w = ['fail' => 0, 'warn' => 1, 'ok' => 2];
      $gs = []; foreach ($snR as $r) { $g = (string)$r['group']; $gs[$g] = $gs[$g] ?? ['n' => 0, 'fail' => 0, 'warn' => 0]; $gs[$g]['n']++; if (isset($gs[$g][$r['status']])) $gs[$g][$r['status']]++; }
      uksort($gs, function ($a, $b) use ($order) { $ia = array_search($a, $order, true); $ib = array_search($b, $order, true); return ($ia === false ? 99 : $ia) <=> ($ib === false ? 99 : $ib); });
      $bad = array_values(array_filter($snR, function ($r) { return $r['status'] !== 'ok'; }));
      usort($bad, function ($a, $b) use ($w) { return [$w[$a['status']] ?? 3, $a['group'], $a['name']] <=> [$w[$b['status']] ?? 3, $b['group'], $b['name']]; });
      $firstG = ''; foreach ($gs as $g => $c) { if ($c['fail'] || $c['warn']) { $firstG = $g; break; } } if ($firstG === '') $firstG = (string)array_key_first($gs);
      $since = function ($id) use ($snst, $tzs) { $t = (int)($snst[$id]['since'] ?? 0); return $t ? gmdate('d/m H:i', $t + $tzs) : '—'; };
      $pill = function ($st) { return $st === 'fail' ? '<span class="pill p-err">Falha</span>' : ($st === 'warn' ? '<span class="pill p-warn">Aviso</span>' : '<span class="pill p-ok">OK</span>'); };
?>
      <section class="stats">
        <div class="stat"><span class="tile t-acc"><?= ic('check') ?></span><div><div class="k">Testes OK</div><div class="v"><?= $cnt['ok'] ?></div></div></div>
        <div class="stat"><span class="tile t-warn"><?= ic('bell') ?></span><div><div class="k">Avisos</div><div class="v"><?= $cnt['warn'] ?></div></div></div>
        <div class="stat"><span class="tile t-vio"><?= ic('ban') ?></span><div><div class="k">Falhas</div><div class="v" style="<?= $cnt['fail'] ? 'color:var(--err)' : '' ?>"><?= $cnt['fail'] ?></div></div></div>
        <div class="stat"><span class="tile t-blue"><?= ic('clock') ?></span><div><div class="k">Último teste</div><div class="v" style="font-size:17px"><?= empty($sn['ts']) ? 'Nunca' : ($snAge < 120 ? 'há ' . $snAge . ' s' : '<span style="color:var(--err)">há ' . (int)round($snAge / 60) . ' min</span>') ?></div></div></div>
      </section>
      <?php if (!$snR): ?><section class="card"><div class="empty"><b>O sentinela ainda não correu</b>Corre sozinho a cada minuto. Usa "Testar agora" para o primeiro teste.</div></section><?php else: ?>
      <section class="card">
        <div class="card-h"><div><h2>O que precisa de atenção</h2><p>Só as falhas e os avisos, de todos os grupos.</p></div></div>
        <?php if (!$bad): ?>
          <div class="sn-allok"><?= ic('check') ?> Tudo a funcionar: <?= count($snR) ?> testes OK<?= !empty($sn['ts']) ? ' · último teste há ' . ($snAge < 120 ? $snAge . ' s' : (int)round($snAge / 60) . ' min') : '' ?>.</div>
        <?php else: ?>
        <table class="list sn-t">
          <colgroup><col style="width:110px"><col style="width:140px"><col style="width:260px"><col><col style="width:130px"></colgroup>
          <thead><tr><th>Estado</th><th>Grupo</th><th>Teste</th><th>Detalhe</th><th>Desde</th></tr></thead>
          <tbody><?php foreach ($bad as $r): ?>
            <tr><td><?= $pill($r['status']) ?></td><td class="mu"><?= h($r['group']) ?></td><td><b><?= h($r['name']) ?></b></td><td class="sn-msg"><?= h($r['msg']) ?></td><td class="mono mu"><?= h($since($r['id'])) ?></td></tr>
          <?php endforeach; ?></tbody>
        </table>
        <?php endif; ?>
      </section>
      <section class="card" id="sn-all" data-first="<?= h($firstG) ?>">
        <div class="card-h"><div><h2>Todos os testes</h2><p>Teste completo em <?= (int)($sn['took'] ?? 0) ?> s · reparação automática <?= !empty($sn['repair']) ? 'ativa (até 3 vezes por hora por serviço)' : 'desligada' ?>.</p></div>
          <input class="in sn-q" id="sn-q" type="search" placeholder="Procurar…" aria-label="Procurar teste"></div>
        <nav class="sn-tabs" role="tablist">
          <?php foreach ($gs as $g => $c): ?>
            <button type="button" class="chip<?= $g === $firstG ? ' prim' : '' ?>" data-g="<?= h($g) ?>"><?= h($g) ?> <span class="sn-cnt"><?= $c['n'] ?></span><?php if ($c['fail']): ?><span class="sn-b sn-b-f"><?= $c['fail'] ?></span><?php endif; ?><?php if ($c['warn']): ?><span class="sn-b sn-b-w"><?= $c['warn'] ?></span><?php endif; ?></button>
          <?php endforeach; ?>
        </nav>
        <table class="list sn-t">
          <colgroup><col style="width:110px"><col style="width:300px"><col><col style="width:130px"></colgroup>
          <thead><tr><th>Estado</th><th>Teste</th><th>Detalhe</th><th>Desde</th></tr></thead>
          <tbody id="sn-rows">
          <?php $all = $snR; usort($all, function ($a, $b) use ($w) { return [$w[$a['status']] ?? 3, $a['name']] <=> [$w[$b['status']] ?? 3, $b['name']]; }); foreach ($all as $r): ?>
            <tr data-g="<?= h($r['group']) ?>"><td><?= $pill($r['status']) ?></td><td><b><?= h($r['name']) ?></b><?= !empty($r['repaired']) ? ' <span class="pill p-me">reparado</span>' : '' ?></td><td class="sn-msg"><?= h($r['msg']) ?></td><td class="mono mu"><?= $r['status'] !== 'ok' ? h($since($r['id'])) : '—' ?></td></tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <div class="card-f" style="display:flex;align-items:center;gap:12px"><span class="mu" id="sn-foot" style="flex:1"></span><nav class="pager" id="sn-pager"></nav></div>
      </section>
      <?php endif; ?>

  <?php elseif ($stab === 'incidentes'):
      $incs = []; foreach (array_reverse(log_tail(MP_STATS . '/sentinel-incidents.log', 5000)) as $ln) { $j = json_decode($ln, true); if (is_array($j)) $incs[] = $j; }
      foreach ($snst as $id => $s0) { if (($s0['status'] ?? 'ok') !== 'ok') { $nm = $id; foreach ($snR as $r) if ($r['id'] === $id) $nm = $r['name']; array_unshift($incs, ['id' => $id, 'name' => $nm, 'start' => (int)$s0['since'], 'end' => 0, 'msg' => (string)$s0['msg'], 'repaired' => false]); } }
      [$il, $ipg, $ipages, $itot] = paginate($incs, 50);
      $dur = function (int $s): string { return $s >= 86400 ? round($s / 86400, 1) . ' d' : ($s >= 3600 ? round($s / 3600, 1) . ' h' : max(1, (int)round($s / 60)) . ' min'); };
  ?>
      <section class="card">
        <div class="card-h"><div><h2>Incidentes</h2><p>Cada falha detetada: quando começou, quanto durou e se foi reparada automaticamente.</p></div></div>
        <?php if (!$incs): ?><div class="empty">Sem incidentes registados.</div><?php else: ?>
        <table class="list cards">
          <thead><tr><th>Início</th><th>Teste</th><th>O que aconteceu</th><th>Duração</th><th>Resultado</th></tr></thead>
          <tbody><?php foreach ($il as $i): ?>
            <tr><td class="first mono" data-label="Início"><?= h(gmdate('d/m/Y H:i', (int)$i['start'] + $tzs)) ?></td><td data-label="Teste"><b><?= h((string)$i['name']) ?></b></td><td class="mu" data-label="O que aconteceu"><?= h((string)$i['msg']) ?></td>
              <td data-label="Duração"><?= empty($i['end']) ? '<span class="pill p-err">a decorrer · ' . h($dur(time() - (int)$i['start'])) . '</span>' : h(!empty($i['repaired']) ? '—' : $dur((int)$i['end'] - (int)$i['start'])) ?></td>
              <td data-label="Resultado"><?= empty($i['end']) ? '<span class="pill p-err">Em falha</span>' : (!empty($i['repaired']) ? '<span class="pill p-me">Reparado sozinho</span>' : '<span class="pill p-ok">Resolvido</span>') ?></td></tr>
          <?php endforeach; ?></tbody>
        </table>
        <div class="card-f"><?= pager($ipg, $ipages, $itot, 'pg', 'incidentes') ?></div>
        <?php endif; ?>
      </section>

  <?php elseif ($stab === 'disponibilidade'):
      $av = jload(MP_STATS . '/sentinel-avail.json') ?? []; $names0 = []; foreach ($snR as $r) $names0[$r['id']] = [$r['name'], $r['group']];
      $days = []; for ($d = 29; $d >= 0; $d--) $days[] = gmdate('Ymd', time() - $d * 86400);
  ?>
      <section class="card">
        <div class="card-h"><div><h2>Disponibilidade nos últimos 30 dias</h2><p>Percentagem de testes sem falha, por dia. Os avisos contam como disponível.</p></div></div>
        <?php if (!$av): ?><div class="empty">Ainda sem dados.</div><?php else: ?>
        <div class="sn-av">
        <?php ksort($av); foreach ($av as $id => $byDay): if (!isset($names0[$id])) continue; $ok = 0; $tot = 0; foreach ($byDay as $c) { $ok += (int)$c[0]; $tot += (int)$c[1]; } $pc = $tot ? $ok * 100 / $tot : 100; ?>
          <div class="sn-row"><div class="sn-n"><b><?= h($names0[$id][0]) ?></b><span class="mu"><?= h($names0[$id][1]) ?></span></div>
            <div class="sn-days"><?php foreach ($days as $d): $c = $byDay[$d] ?? null; $p = $c && $c[1] ? $c[0] * 100 / $c[1] : null; ?><i class="<?= $p === null ? 'n' : ($p >= 99.9 ? 'g' : ($p >= 98 ? 'y' : 'r')) ?>" title="<?= h(substr($d, 6, 2) . '/' . substr($d, 4, 2)) ?>: <?= $p === null ? 'sem dados' : number_format($p, 2, ',', '') . '%' ?>"></i><?php endforeach; ?></div>
            <b class="sn-pc" style="<?= $pc < 99 ? 'color:var(--err)' : '' ?>"><?= number_format($pc, 2, ',', '') ?>%</b></div>
        <?php endforeach; ?>
        </div><?php endif; ?>
      </section>

  <?php else: $scfg = (array)($state['sentinel'] ?? []); ?>
      <section class="card">
        <div class="card-h"><div><h2>Configuração do sentinela</h2><p>Testa todos os serviços a cada minuto. As falhas e as reparações são enviadas pelos canais de Alertas (SMS e email).</p></div></div>
        <form method="post" class="card-b">
          <?= act_fields('sentinel_settings') ?>
          <div class="fgrid">
            <label class="fld">Reparação automática<select class="in" name="repair"><option value="on"<?= !isset($scfg['repair']) || !empty($scfg['repair']) ? ' selected' : '' ?>>Ativa: reinicia o serviço em falha (até 3 vezes por hora)</option><option value="off"<?= isset($scfg['repair']) && empty($scfg['repair']) ? ' selected' : '' ?>>Desligada: só alerta</option></select></label>
            <label class="fld">Testar a página inicial dos sites<select class="in" name="sites"><option value="on"<?= !isset($scfg['sites']) || !empty($scfg['sites']) ? ' selected' : '' ?>>Sim (deteta erros 5xx da aplicação)</option><option value="off"<?= isset($scfg['sites']) && empty($scfg['sites']) ? ' selected' : '' ?>>Não (só o PHP de cada site)</option></select></label>
          </div>
          <?php if ($snR): ?><p class="mu" style="margin:16px 0 8px">Testes ativos (desmarca os que não queres que sejam feitos):</p>
          <div class="sn-chk"><?php foreach ($snR as $r): ?><label class="chk"><input type="checkbox" name="on[]" value="<?= h($r['id']) ?>"<?= strpos(' ' . $snOff . ' ', ' ' . $r['id'] . ' ') === false ? ' checked' : '' ?>> <?= h($r['group'] . ': ' . $r['name']) ?></label><?php endforeach; ?>
            <?php foreach (array_filter(explode(' ', $snOff)) as $oid): ?><label class="chk"><input type="checkbox" name="on[]" value="<?= h($oid) ?>"> <?= h($oid) ?> <span class="mu">(desligado)</span></label><?php endforeach; ?></div>
          <input type="hidden" name="all" value="<?= h(implode(' ', array_unique(array_merge(array_column($snR, 'id'), array_filter(explode(' ', $snOff)))))) ?>"><?php endif; ?>
          <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
        </form>
      </section>
  <?php endif; ?>

<?php elseif ($page === 'manual'):
    $mdToc = []; $mdHtml = is_readable(MP_MANUAL) ? md_render((string)file_get_contents(MP_MANUAL), $mdToc) : '';
?>
<?php if ($mdHtml === ''): ?>
      <section class="card"><div class="empty"><b>Manual não encontrado</b>Volta a correr o instalador para o repor (<span class="mono"><?= h(MP_MANUAL) ?></span>).</div></section>
<?php else: ?>
      <div class="md-wrap">
        <aside class="card md-toc">
          <div class="md-toc-h">
            <input class="in" id="md-q" type="search" placeholder="Procurar…" aria-label="Procurar no manual" autocomplete="off">
            <a class="chip sm" href="?manual=dl" title="Descarregar o manual em Markdown"><?= ic('download') ?><span class="lbl">.md</span></a>
          </div>
          <nav class="md-nav">
            <?php foreach ($mdToc as $t): ?>
              <a href="#<?= h($t['id']) ?>" class="md-n2"><?= h($t['t']) ?></a>
              <?php foreach ($t['sub'] as $s2): ?><a href="#<?= h($s2['id']) ?>" class="md-n3" data-sec="<?= h($t['id']) ?>"><?= h($s2['t']) ?></a><?php endforeach; ?>
            <?php endforeach; ?>
          </nav>
          <p class="mu md-none" id="md-none" hidden>Nada encontrado.</p>
        </aside>
        <article class="card md-body" id="md-body"><?= $mdHtml ?></article>
      </div>
<?php endif; ?>

<?php elseif ($page === 'auditoria'):
    $alog = [];
    $af = MP_DATA . '/logs/audit.log';
    if (is_file($af)) {
        $sz = (int)filesize($af); $fh = @fopen($af, 'r');
        if ($fh) { if ($sz > 2000000) fseek($fh, $sz - 2000000); $buf = (string)stream_get_contents($fh); fclose($fh);
            foreach (array_slice(array_reverse(array_filter(explode("\n", $buf))), 0, 1000) as $ln) { $j = json_decode($ln, true); if (is_array($j)) $alog[] = $j; } }
    }
    $tza = tz_off(live_stats());
    $auUsers = array_values(array_unique(array_map(function ($e) { return (string)($e['user'] ?? ''); }, $alog))); sort($auUsers);
    $auQ = trim(qget('q')); $auU = qget('u'); $auR = qget('r'); $auAll = count($alog);
    $alog = array_values(array_filter($alog, function ($e) use ($auQ, $auU, $auR) {
        if ($auU !== '' && (string)($e['user'] ?? '') !== $auU) return false;
        if ($auR === 'ok' && empty($e['ok'])) return false;
        if ($auR === 'falhou' && !empty($e['ok'])) return false;
        return $auQ === '' || stripos(($e['action'] ?? '') . ' ' . ($e['ip'] ?? '') . ' ' . ($e['user'] ?? ''), $auQ) !== false;
    }));
?>
      <section class="card">
        <div class="card-h"><div><h2>Registo de auditoria</h2><p>Inícios de sessão e todas as ações feitas no painel, com data, utilizador e IP.</p></div></div>
        <form class="au-f" method="get">
          <input type="hidden" name="p" value="auditoria">
          <input class="in" name="q" type="search" value="<?= h($auQ) ?>" placeholder="Procurar ação, IP ou utilizador…" aria-label="Procurar">
          <select class="in" name="u" aria-label="Utilizador"><option value="">Todos os utilizadores</option><?php foreach ($auUsers as $uu): ?><option<?= $uu === $auU ? ' selected' : '' ?>><?= h($uu) ?></option><?php endforeach; ?></select>
          <select class="in" name="r" aria-label="Resultado"><option value="">Todos os resultados</option><option value="ok"<?= $auR === 'ok' ? ' selected' : '' ?>>OK</option><option value="falhou"<?= $auR === 'falhou' ? ' selected' : '' ?>>Falhou</option></select>
          <button class="btn sm" type="submit">Filtrar</button>
          <?php if ($auQ !== '' || $auU !== '' || $auR !== ''): ?><a class="btn sm sec" href="?p=auditoria">Limpar</a><span class="mu"><?= count($alog) ?> de <?= $auAll ?> registos</span><?php endif; ?>
        </form>
        <?php if (!$alog): ?>
          <div class="empty"><?= $auAll ? 'Nenhum registo com estes filtros.' : 'Ainda não há registos.' ?></div>
        <?php else: ?>
        <table class="list cards au-t" id="au-t">
          <colgroup><col style="width:215px"><col style="width:150px"><col style="width:190px"><col><col style="width:120px"></colgroup>
          <thead><tr><th>Data</th><th>Utilizador</th><th>IP</th><th>Ação</th><th>Resultado</th></tr></thead>
          <tbody>
          <?php [$pgList, $pgN, $pgPages, $pgTot] = paginate($alog, 50); foreach ($pgList as $e): ?>
            <tr>
              <td class="first" data-label="Data"><span class="mono"><?= h(gmdate('d/m/Y H:i:s', (int)($e['ts'] ?? 0) + $tza)) ?></span></td>
              <td data-label="Utilizador"><?= h($e['user'] ?? '') ?></td>
              <td data-label="IP" class="mono"><?= h($e['ip'] ?? '') ?></td>
              <td data-label="Ação"><?= h($e['action'] ?? '') ?></td>
              <td data-label="Resultado"><span class="pill <?= !empty($e['ok']) ? 'p-ok' : 'p-err' ?>"><?= !empty($e['ok']) ? 'OK' : 'Falhou' ?></span></td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php if ($pgPages > 1): ?><div class="card-f"><?= pager($pgN, $pgPages, $pgTot, 'pg', 'registos') ?></div><?php endif; ?>
        <?php endif; ?>
        <div class="card-f mu">Mostra os últimos 1000 registos. O ficheiro completo está em /var/lib/minipainel/logs/audit.log e é rodado semanalmente (8 semanas).</div>
      </section>

<?php elseif ($page === 'servicos'): ?>
      <section class="card">
        <?php if (!$svcs): ?>
          <div class="empty">Sem informação dos serviços.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Serviço</th><th>Estado</th><th>Utilização</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($svcs as $s): $on = !empty($s['active']); ?>
            <tr>
              <td class="first" data-label="Serviço"><div class="who"><span class="av <?= $on ? 't-acc' : 't-warn' ?>"><?= ic(($s['id'] ?? '') === 'mariadb' ? 'db' : ((($s['id'] ?? '') === 'nginx') ? 'world' : 'code')) ?></span><div><div class="nm"><?= h($s['name'] ?? '') ?></div><div class="mu mono"><?= h($s['unit'] ?? '') ?></div></div></div></td>
              <td data-label="Estado"><span class="pill <?= $on ? 'p-ok' : 'p-err' ?>"><?= $on ? 'Ativo' : 'Parado' ?></span></td>
              <td data-label="Utilização" class="mu"><?= h(svc_usage($s, $bySite)) ?></td>
              <td data-label="Ações"><?= svc_actions($s, $bySite) ?></td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
        <div class="card-f mu">Recarregar aplica configurações sem cortar ligações. Antes de cada ação a configuração é testada; se tiver erros, nada é alterado. Os serviços arrancam sozinhos quando o servidor reinicia.</div>
      </section>

<?php else:
    $has2fa = !empty($auth['totp']);
    $tfaNew = '';
    if (!$has2fa && qget('tfa') === 'setup') {
        if (empty($_SESSION['totp_new'])) $_SESSION['totp_new'] = b32_encode(random_bytes(20));
        $tfaNew = (string)$_SESSION['totp_new'];
    }
?>
      <div class="grid2e">
      <section class="card">
        <div class="card-h"><div><h2>Utilizador</h2><p>Nome usado para iniciar sessão no painel.</p></div></div>
        <form method="post" class="card-b">
          <?= act_fields('acct_user') ?>
          <div class="fgrid">
            <label class="fld">Novo nome de utilizador<input class="in" name="newuser" required pattern="[a-z][a-z0-9._\-]{2,31}" value="<?= h($_SESSION['user']) ?>" autocomplete="off"><small>3 a 32 caracteres; evita nomes óbvios como admin</small></label>
            <label class="fld">Password atual<input class="in" type="password" name="atual" required autocomplete="current-password"></label>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Mudar nome</button></div>
        </form>
      </section>

      <section class="card">
        <div class="card-h"><div><h2>Verificação em dois passos</h2><p>Pede um código de uma aplicação (Google Authenticator, Microsoft Authenticator, 1Password, Bitwarden…) depois da password.</p></div><span class="pill <?= $has2fa ? 'p-ok' : 'p-off' ?>"><?= $has2fa ? 'Ativa' : 'Desativada' ?></span></div>
        <?php if ($has2fa): ?>
        <form method="post" class="card-b">
          <?= act_fields('totp_disable') ?>
          <div class="fgrid">
            <label class="fld">Password atual<input class="in" type="password" name="atual" required autocomplete="current-password"></label>
            <label class="fld">Código atual<input class="in mono" name="code" required inputmode="numeric" autocomplete="one-time-code" maxlength="14"></label>
          </div>
          <div style="margin-top:16px"><button class="btn dan" type="submit">Desativar</button></div>
        </form>
        <?php elseif ($tfaNew !== ''): $uri = 'otpauth://totp/' . rawurlencode('IDDigital Hosting:' . $_SESSION['user'] . '@' . ($sys['hostname'] ?? 'servidor')) . '?secret=' . $tfaNew . '&issuer=' . rawurlencode('IDDigital Hosting') . '&digits=6&period=30'; ?>
        <form method="post" class="card-b tfa">
          <?= act_fields('totp_enable') ?>
          <div class="tfa-qr" id="tfa-qr" data-uri="<?= h($uri) ?>"></div>
          <div class="tfa-side">
            <p style="margin:0">1. Lê o código QR com a aplicação, ou introduz a chave manualmente:</p>
            <div class="mono tfa-key"><?= h(trim(chunk_split($tfaNew, 4, ' '))) ?></div>
            <label class="fld">2. Código de 6 dígitos mostrado na aplicação<input class="in mono" name="code" required inputmode="numeric" autocomplete="one-time-code" maxlength="6" autofocus></label>
            <div style="display:flex;gap:8px"><button class="btn" type="submit">Ativar</button><a class="btn sec" href="?p=conta">Cancelar</a></div>
          </div>
        </form>
        <?php else: ?>
        <div class="card-b"><a class="btn" href="?p=conta&amp;tfa=setup">Ativar verificação em dois passos</a></div>
        <?php endif; ?>
        <div class="card-f mu">Ao ativar recebes 8 códigos de recuperação. Se perderes o telemóvel e os códigos, desativa na consola do servidor: <span class="mono">mpanel panel-2fa off</span></div>
      </section>
      </div>

      <section class="card" style="max-width:none">
        <div class="card-h"><h2>Password do painel</h2><p>Utilizador: <?= h($_SESSION['user']) ?></p></div>
        <form method="post" class="card-b">
          <?= act_fields('conta_pass') ?>
          <div class="fgrid" style="grid-template-columns:repeat(auto-fit,minmax(220px,1fr))">
            <label class="fld">Password atual<input class="in" type="password" name="atual" required autocomplete="current-password"></label>
            <label class="fld">Nova password<input class="in" type="password" name="nova" required minlength="10" autocomplete="new-password"><small>Mínimo 10 caracteres</small></label>
            <label class="fld">Repetir nova password<input class="in" type="password" name="repetir" required minlength="10" autocomplete="new-password"></label>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Alterar password</button></div>
        </form>
        <div class="card-f mu">No servidor também podes usar <span class="mono">mpanel passwd</span>.</div>
      </section>
<?php endif; ?>
    </main>
  </div>
</div>

<!-- Novo site -->
<dialog class="drawer" id="dlg-site-new" aria-labelledby="t-site-new">
  <form method="post">
    <?= act_fields('site_add') ?>
    <div class="dlg-h"><div><h3 id="t-site-new">Novo site</h3><p>Fica acessível em http://IP:porta e http://localhost:porta.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b">
      <label class="fld">Nome<input class="in" name="site" required maxlength="24" pattern="[a-z][a-z0-9\-]{0,23}" placeholder="loja" autocomplete="off"><small>Minúsculas, números e "-", a começar por letra</small></label>
      <div class="fgrid">
        <label class="fld">Porta<input class="in" name="port" inputmode="numeric" pattern="[0-9]{1,5}" placeholder="automática" autocomplete="off"><small>Vazio = próxima livre a partir de 8001</small></label>
        <label class="fld">Versão de PHP<select class="in" name="php"><?= php_options($phps, $defPhp) ?></select></label>
      </div>
      <div class="fsec">Domínio<?= $isNet ? '' : ' (opcional)' ?></div>
      <div class="fgrid">
        <label class="fld">Domínios<input class="in mono" name="domains" placeholder="loja.pt www.loja.pt" autocomplete="off"><small>Separados por espaço; vazio = só por porta</small></label>
        <label class="fld">Certificado SSL<select class="in" name="ssl"><option value="le"<?= $isNet ? ' selected' : '' ?>>Let's Encrypt</option><option value="self">Autoassinado</option><option value="none"<?= $isNet ? '' : ' selected' ?>>Sem SSL</option></select></label>
      </div>
      <div class="fsec">Limites do PHP</div>
      <?= limit_fields(LIMIT_DEFAULTS + ['display_errors' => false]) ?>
    </div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Criar site</button></div>
  </form>
</dialog>

<!-- Nova base de dados -->
<dialog class="drawer" id="dlg-db-new" aria-labelledby="t-db-new">
  <form method="post">
    <?= act_fields('db_add') ?>
    <div class="dlg-h"><div><h3 id="t-db-new">Nova base de dados</h3><p>O utilizador é criado com o mesmo nome.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b">
      <label class="fld">Nome<input class="in mono" name="db" required maxlength="32" pattern="[a-z][a-z0-9_]{0,31}" placeholder="loja_db" autocomplete="off"><small>Minúsculas, números e "_", a começar por letra</small></label>
      <label class="fld">Password<input class="in" name="pw" type="password" maxlength="64" autocomplete="new-password"><small>Vazio = gerada automaticamente e mostrada no fim</small></label>
      <label class="fld">Site associado<select class="in" name="site"><option value="">Nenhum</option><?php foreach ($sites as $ss): $ssn = (string)$ss['name']; ?><option value="<?= h($ssn) ?>"><?= h($ssn) ?></option><?php endforeach; ?></select><small>Entra nos backups do site e é reposta com ele</small></label>
    </div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Criar base de dados</button></div>
  </form>
</dialog>

<?php foreach ($sites as $s): $n = (string)($s['name'] ?? ''); if (!valid_site($n)) continue; $L = site_limits($s); ?>
<dialog class="drawer" id="dlg-perf-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('site_perf', ['site' => $n]) ?>
    <?php $pf = is_array($s['perf'] ?? null) ? $s['perf'] : ['cache' => 0, 'pm' => 'ondemand', 'maxch' => 10, 'slow' => 5]; ?>
    <div class="dlg-h"><div><h3>Desempenho de <?= h($n) ?></h3><p>Cache de página, processos PHP e registo de scripts lentos.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b">
      <label class="fld">Cache de página<select class="in" name="cache">
        <?php foreach (['0' => 'Desligada', '60' => '1 minuto', '300' => '5 minutos', '600' => '10 minutos', '1800' => '30 minutos', '3600' => '1 hora'] as $k => $l): ?><option value="<?= $k ?>"<?= (int)$pf['cache'] === (int)$k ? ' selected' : '' ?>><?= $l ?></option><?php endforeach; ?>
      </select><small>As páginas ficam guardadas e são servidas sem executar o PHP. Nunca entram em cache: sessões iniciadas, carrinhos, checkout, áreas de cliente e de administração, formulários (POST).</small></label>
      <div class="fgrid">
        <label class="fld">Processos PHP<select class="in" name="pm"><option value="ondemand"<?= $pf['pm'] !== 'dynamic' ? ' selected' : '' ?>>A pedido (poupa memória)</option><option value="dynamic"<?= $pf['pm'] === 'dynamic' ? ' selected' : '' ?>>Sempre prontos (mais rápido)</option></select><small>"Sempre prontos" evita o atraso da primeira visita depois de uma pausa</small></label>
        <label class="fld">Máximo de processos<input class="in" name="maxch" inputmode="numeric" pattern="[0-9]{1,3}" value="<?= (int)$pf['maxch'] ?>"><small>Visitas atendidas em simultâneo (cada processo usa até ao limite de memória do site)</small></label>
      </div>
      <label class="fld">Registar scripts lentos<select class="in" name="slow">
        <?php foreach (['0' => 'Não registar', '1' => 'Acima de 1 segundo', '3' => 'Acima de 3 segundos', '5' => 'Acima de 5 segundos', '10' => 'Acima de 10 segundos'] as $k => $l): ?><option value="<?= $k ?>"<?= (int)$pf['slow'] === (int)$k ? ' selected' : '' ?>><?= $l ?></option><?php endforeach; ?>
      </select><small>Mostra o ficheiro e a função que estava a correr quando o pedido demorou (Logs → PHP lento)</small></label>
      <h4 class="dlg-sec">Redis (cache de objetos)</h4>
      <div class="fgrid">
        <label class="fld">Redis do site<select class="in" name="redis"><option value="off"<?= empty($pf['redis']) ? ' selected' : '' ?>>Desligado</option><option value="on"<?= !empty($pf['redis']) ? ' selected' : '' ?>>Ligado</option></select></label>
        <label class="fld">Memória<select class="in" name="redis_mb"><?php foreach ([32, 64, 128, 256, 512, 1024] as $mb): ?><option value="<?= $mb ?>"<?= (int)($pf['redis_mb'] ?? 128) === $mb ? ' selected' : '' ?>><?= $mb ?> MB</option><?php endforeach; ?></select></label>
      </div>
      <?php if (!empty($pf['redis'])): ?><div class="infobox"><b>Ligação:</b> socket <span class="mono"><?= h((string)$pf['sock']) ?></span> (sem password; só este site lhe chega).<br>
        <b>WordPress</b> (plugin "Redis Object Cache"), no <span class="mono">wp-config.php</span>:<br><span class="mono">define('WP_REDIS_SCHEME', 'unix');<br>define('WP_REDIS_PATH', '<?= h((string)$pf['sock']) ?>');</span><br>
        <b>PrestaShop / OpenCart / outros:</b> no módulo ou na configuração de cache, Redis com o caminho da socket acima.</div><?php else: ?><small class="mu">Guarda em memória as consultas repetidas da aplicação (WordPress, WooCommerce, PrestaShop…). Cada site tem o seu Redis, isolado dos outros.</small><?php endif; ?>
      <h4 class="dlg-sec">Ficheiros estáticos</h4>
      <div class="fgrid">
        <label class="fld">Cache no browser<select class="in" name="static_days"><?php foreach (['0' => 'Desligada', '7' => '7 dias', '30' => '30 dias', '365' => '1 ano'] as $k => $l): ?><option value="<?= $k ?>"<?= (int)($pf['static_days'] ?? 30) === (int)$k ? ' selected' : '' ?>><?= $l ?></option><?php endforeach; ?></select><small>Imagens, CSS, JS e fontes não voltam a ser descarregados por quem regressa ao site</small></label>
        <label class="fld">WebP automático<select class="in" name="webp"><option value="on"<?= !empty($pf['webp']) ? ' selected' : '' ?>>Sim</option><option value="off"<?= empty($pf['webp']) ? ' selected' : '' ?>>Não</option></select><small>Se existir imagem.jpg.webp, é entregue aos browsers que o suportam</small></label>
      </div>
      <label class="chk"><input type="checkbox" name="webp_auto" value="1"<?= !empty($pf['webp_auto']) ? ' checked' : '' ?>> Converter as imagens novas em WebP todas as noites</label>
    </div>
    <div class="dlg-f">
      <div style="margin-right:auto;display:flex;gap:8px;flex-wrap:wrap"><?php if ((int)$pf['cache'] > 0): ?><button class="btn sec" type="submit" form="cache-purge-<?= h($n) ?>">Limpar cache</button><?php endif; ?><button class="btn sec" type="submit" form="webp-now-<?= h($n) ?>" title="Converte todas as imagens JPG e PNG do site (pode demorar)">Converter imagens</button></div>
      <button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Guardar</button>
    </div>
  </form>
</dialog>
<form method="post" id="cache-purge-<?= h($n) ?>" style="display:none"><?= act_fields('cache_purge', ['site' => $n]) ?></form>
<form method="post" id="webp-now-<?= h($n) ?>" style="display:none"><?= act_fields('site_webp', ['site' => $n]) ?></form>
<dialog class="drawer" id="dlg-ftp-<?= h($n) ?>">
  <form method="post" autocomplete="off">
    <?= act_fields('site_ftp', ['site' => $n]) ?>
    <div class="dlg-h"><div><h3>Acesso FTP/SFTP de <?= h($n) ?></h3><p>Uma conta com acesso à pasta do site; a mesma password serve para FTPS e SFTP.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b">
      <div class="kv"><span>Estado</span><b><?= !empty($s['ftp']) ? '<span class="pill p-ok">Ativo</span>' : '<span class="pill p-off">Desativado</span>' ?></b></div>
      <div class="kv"><span>Servidor</span><b class="mono"><?= h($host) ?></b></div>
      <div class="kv"><span>FTPS (porta 21, TLS explícito)</span><b class="mono"><?= h($n) ?></b></div>
      <div class="kv"><span>SFTP (porta 22)</span><b class="mono">mp_<?= h($n) ?></b></div>
      <label class="fld" style="margin-top:6px"><?= !empty($s['ftp']) ? 'Nova password' : 'Password' ?><input class="in" type="password" name="pw" minlength="10" autocomplete="new-password"><small>Vazio = gerada e mostrada no fim</small></label>
      <p class="mu" style="margin:0">Ao entrar, a conta fica limitada à pasta <span class="mono">/srv/www/<?= h($n) ?></span> (public_html, logs, tmp). Os ficheiros enviados ficam com o dono do site. Ao fim de várias passwords erradas, o IP é bloqueado.</p>
    </div>
    <div class="dlg-f">
      <?php if (!empty($s['ftp'])): ?><button class="btn sec dan" type="submit" form="ftp-off-<?= h($n) ?>" style="margin-right:auto">Desativar</button><?php endif; ?>
      <button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit"><?= !empty($s['ftp']) ? 'Mudar password' : 'Ativar acesso' ?></button>
    </div>
  </form>
</dialog>
<form method="post" id="ftp-off-<?= h($n) ?>" data-confirm="Desativar o acesso FTP/SFTP de <?= h($n) ?>?" style="display:none"><?= act_fields('site_ftp', ['site' => $n, 'off' => '1']) ?></form>
<dialog class="drawer" id="dlg-dom-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('site_domains', ['site' => $n]) ?>
    <div class="dlg-h"><div><h3>Domínios e SSL de <?= h($n) ?></h3><p>O site continua acessível pela porta <?= (int)($s['port'] ?? 0) ?>.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b">
      <label class="fld">Domínios<textarea class="in mono cron-ta" name="domains" rows="4" placeholder="loja.pt&#10;www.loja.pt" spellcheck="false"><?= h(str_replace(' ', "\n", (string)($s['domains'] ?? ''))) ?></textarea><small>Um por linha. Cada domínio tem de apontar (DNS) para este servidor.</small></label>
      <div class="fgrid">
        <label class="fld">Certificado SSL<select class="in" name="ssl"><?php $cs = (string)($s['ssl'] ?? 'none'); ?><option value="le"<?= $cs === 'le' ? ' selected' : '' ?>>Let's Encrypt</option><option value="self"<?= $cs === 'self' ? ' selected' : '' ?>>Autoassinado (LAN)</option><option value="none"<?= $cs === 'none' ? ' selected' : '' ?>>Sem SSL</option></select></label>
        <label class="fld">Endereço principal<select class="in" name="www"><?php $cw = (string)($s['www'] ?? 'keep'); ?><option value="keep"<?= $cw === 'keep' ? ' selected' : '' ?>>Aceitar todos como estão</option><option value="root"<?= $cw === 'root' ? ' selected' : '' ?>>Redirecionar para sem www</option><option value="www"<?= $cw === 'www' ? ' selected' : '' ?>>Redirecionar para com www</option></select></label>
      </div>
      <label class="chk"><input type="checkbox" name="https" value="1"<?= ($s['https'] ?? '1') !== '0' ? ' checked' : '' ?>> Redirecionar HTTP para HTTPS (quando houver certificado)</label>
      <?php if (!empty($s['ssl_exp'])): ?><div class="mu">Certificado <?= ($s['ssl'] ?? '') === 'le' ? "Let's Encrypt" : 'autoassinado' ?> válido até <?= h(gmdate('d/m/Y', (int)$s['ssl_exp'])) ?><?= ($s['ssl'] ?? '') === 'le' ? '; é renovado automaticamente.' : '.' ?></div><?php endif; ?>
      <div class="warnbox">Lojas como PrestaShop, WooCommerce e OpenCart guardam o endereço na própria base de dados: depois de associares um domínio, atualiza-o também nas definições da loja.</div>
    </div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Guardar</button></div>
  </form>
</dialog>
<dialog class="drawer" id="dlg-lim-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('site_limits', ['site' => $n]) ?>
    <div class="dlg-h"><div><h3>Limites de <?= h($n) ?></h3><p>Aplicados ao PHP-FPM e ao nginx deste site.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b">
      <?= limit_fields($L) ?>
      <div class="mu">O upload máximo também define o tamanho máximo de pedido no nginx (client_max_body_size). Se a configuração falhar, os valores anteriores são repostos.</div>
    </div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Guardar limites</button></div>
  </form>
</dialog>
<dialog id="dlg-php-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('site_php', ['site' => $n]) ?>
    <div class="dlg-h"><h3>Versão de PHP de <?= h($n) ?></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b"><label class="fld">Versão<select class="in" name="php"><?= php_options($phps, (string)($s['php'] ?? '')) ?></select><small>A troca é feita sem interromper o site.</small></label></div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Mudar versão</button></div>
  </form>
</dialog>
<dialog id="dlg-del-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('site_del', ['site' => $n]) ?>
    <div class="dlg-h"><h3>Apagar o site <?= h($n) ?>?</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b">
      <div class="warnbox">O site deixa de estar acessível na porta <?= (int)($s['port'] ?? 0) ?>, e o utilizador de sistema e a configuração são removidos. As bases de dados não são apagadas.</div>
      <label class="chk"><input type="checkbox" name="keep" value="1"> Manter os ficheiros em <?= h('/srv/www/' . $n) ?></label>
    </div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn dan" type="submit">Apagar site</button></div>
  </form>
</dialog>
<?php endforeach; ?>

<?php foreach ($dbs as $d): $n = (string)($d['name'] ?? ''); if (!preg_match(RX_DB, $n)) continue; ?>
<dialog id="dlg-dblink-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('db_link', ['db' => $n]) ?>
    <div class="dlg-h"><h3>Associar <?= h($n) ?> a um site</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b"><label class="fld">Site<select class="in" name="site"><option value="none">Nenhum</option><?php foreach ($sites as $ss): $ssn = (string)$ss['name']; ?><option value="<?= h($ssn) ?>"<?= ($d['site'] ?? '') === $ssn ? ' selected' : '' ?>><?= h($ssn) ?></option><?php endforeach; ?></select><small>A base de dados passa a entrar nos backups do site e é reposta com ele.</small></label></div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Guardar</button></div>
  </form>
</dialog>
<dialog id="dlg-dbpw-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('db_pass', ['db' => $n]) ?>
    <div class="dlg-h"><h3>Nova password para <?= h($n) ?></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b"><label class="fld">Password<input class="in" name="pw" type="password" maxlength="64" autocomplete="new-password"><small>Vazio = gerada automaticamente e mostrada no fim</small></label></div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Mudar password</button></div>
  </form>
</dialog>
<dialog id="dlg-dbdel-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('db_del', ['db' => $n]) ?>
    <div class="dlg-h"><h3>Apagar a base de dados <?= h($n) ?>?</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b"><div class="warnbox">A base de dados e o utilizador <?= h($n) ?>@localhost são apagados. Esta ação não pode ser anulada.</div></div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn dan" type="submit">Apagar base de dados</button></div>
  </form>
</dialog>
<?php endforeach; ?>

<div class="toasts" aria-live="polite">
  <?php foreach ($jobs as $j): ?>
    <div class="toast pending"><span class="ti"><span class="spin"></span></span><div class="msg"><?= h(($j['label'] ?? 'Tarefa') . '…') ?></div></div>
  <?php endforeach; ?>
  <?php foreach ($flashes as $f): $sticky = !empty($f[2]); $m = (string)$f[1]; ?>
    <div class="toast <?= $f[0] ? 'ok' : 'err' ?>"<?= $sticky ? '' : ' data-auto' ?>>
      <span class="ti"><?= ic($f[0] ? 'check' : 'alert') ?></span>
      <div class="msg<?= strpos($m, "\n") !== false ? ' mono' : '' ?>"><?= h($m) ?></div>
      <button type="button" data-dismiss aria-label="Fechar"><?= ic('x') ?></button>
    </div>
  <?php endforeach; ?>
</div>

<script>
(function () {
  var $ = function (s, c) { return (c || document).querySelectorAll(s); };
  function openDlg(id) { var d = document.getElementById(id); if (d && d.showModal && !d.open) { closeMenus(); d.showModal(); var f = d.querySelector('input:not([type=hidden]),select'); if (f) f.focus(); } }
  function closeMenus(except) { $('details.dd[open]').forEach(function (x) { if (x !== except) x.removeAttribute('open'); }); }
  document.addEventListener('click', function (e) {
    var t = e.target.closest('[data-open]');
    if (t) { e.preventDefault(); openDlg(t.getAttribute('data-open')); return; }
    var c = e.target.closest('[data-close]');
    if (c) { var d = c.closest('dialog'); if (d) d.close(); return; }
    if (e.target.closest('[data-dismiss]')) { e.target.closest('.toast').remove(); return; }
    if (e.target.closest('[data-nav-open]')) { document.body.classList.add('nav-open'); return; }
    if (e.target.closest('[data-nav-close]')) { document.body.classList.remove('nav-open'); return; }
    if (e.target.closest('[data-theme-toggle]')) {
      var n = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
      document.documentElement.setAttribute('data-theme', n);
      try { localStorage.setItem('mp-theme', n); } catch (x) {}
      return;
    }
    if (!e.target.closest('details.dd')) closeMenus();
  });
  $('details.dd').forEach(function (d) { d.addEventListener('toggle', function () { if (d.open) closeMenus(d); }); });
  $('dialog').forEach(function (d) { d.addEventListener('click', function (e) { if (e.target === d && !d.hasAttribute('data-keep')) d.close(); }); });
  document.addEventListener('submit', function (e) {
    var f = e.target, m = f.getAttribute('data-confirm');
    if ((f.getAttribute('method') || '').toLowerCase() === 'dialog') return;
    if (m && !window.confirm(m)) { e.preventDefault(); return; }
    setTimeout(function () { $('button', f).forEach(function (b) { b.disabled = true; }); }, 0);
  });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') { closeMenus(); document.body.classList.remove('nav-open'); } });
  $('.toast[data-auto]').forEach(function (t) { setTimeout(function () { t.remove(); }, 6000); });
  var o = document.body.getAttribute('data-autoopen');
  if (o) openDlg(o);
  if (parseInt(document.body.getAttribute('data-pending'), 10) > 0) {
    var poll = function () {
      fetch('?poll=1', { credentials: 'same-origin', cache: 'no-store' })
        .then(function (r) { if (r.status === 401) return { pending: 0 }; return r.json(); })
        .then(function (d) { if (d.pending > 0) setTimeout(poll, 1000); else location.replace(location.pathname + location.search.replace(/[?&](novo|limites)=[^&]*/g, '')); })
        .catch(function () { setTimeout(poll, 1500); });
    };
    setTimeout(poll, 700);
  }
})();
</script>
<?php if ($page === 'conta' && !empty($_SESSION['totp_new']) && qget('tfa') === 'setup'): ?>
<script src="?asset=qr"></script>
<script>
(function () { var el = document.getElementById('tfa-qr'); if (!el || typeof qrcode !== 'function') return;
  var q = qrcode(0, 'M'); q.addData(el.getAttribute('data-uri')); q.make(); el.innerHTML = q.createSvgTag(5, 4); })();
</script>
<?php endif; ?>
<?php if ($page === 'logs'): ?>
<script>
(function () {
  var box = document.getElementById('lg'); if (!box) return;
  var site = box.getAttribute('data-site'), t = box.getAttribute('data-t'), body = document.getElementById('lg-body'), lgPg = 1;
  var $ = function (id) { return document.getElementById(id); };
  function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); }
  function pill(s) { var c = s >= 500 ? 'p-err' : (s >= 400 ? 'p-warn' : (s >= 300 ? 'p-off' : 'p-ok')); return '<span class="pill ' + c + '">' + s + '</span>'; }
  function fdate(t) { var d = new Date(t * 1000), p = function (n) { return (n < 10 ? '0' : '') + n; }; return p(d.getDate()) + '/' + p(d.getMonth() + 1) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds()); }
  function raw(lines) {
    if (!lines.length) { body.innerHTML = '<div class="empty">Sem linhas' + ($('lg-q').value ? ' com esse texto' : '') + '.</div>'; return; }
    body.innerHTML = '<pre class="cron-out lg-raw">' + lines.slice().reverse().map(esc).join('\n') + '</pre>';
  }
  function load() {
    var n = $('lg-n').value, q = $('lg-q').value.trim(), url;
    if (t === 'access' || t === 'error' || t === 'slow') {
      url = '?logs=json&site=' + encodeURIComponent(site) + '&t=' + t + '&n=' + n + '&q=' + encodeURIComponent(q);
      if (t === 'access') url += '&st=' + encodeURIComponent($('lg-st').value) + '&ip=' + encodeURIComponent($('lg-ip').value.trim());
      fetch(url, { credentials: 'same-origin' }).then(function (r) { return r.json(); }).then(function (d) {
        if (t !== 'access') return raw(d.lines || []);
        var rows = (d.rows || []).slice().reverse(), pages = Math.max(1, Math.ceil(rows.length / 50));
        if (!rows.length) { body.innerHTML = '<div class="empty">Sem pedidos com estes filtros.</div>'; return; }
        if (lgPg > pages) lgPg = pages;
        var pgr = ''; if (pages > 1) { pgr = '<nav class="pager lg-pager"><span class="mu">' + rows.length + ' pedidos</span>';
          if (lgPg > 1) pgr += '<button type="button" class="chip sm" data-lgp="' + (lgPg - 1) + '">‹ Anterior</button>';
          [1, lgPg - 2, lgPg - 1, lgPg, lgPg + 1, lgPg + 2, pages].filter(function (x, k, a) { return x >= 1 && x <= pages && a.indexOf(x) === k; }).sort(function (a, b) { return a - b; })
            .forEach(function (x) { pgr += '<button type="button" class="chip sm' + (x === lgPg ? ' prim' : '') + '" data-lgp="' + x + '">' + x + '</button>'; });
          if (lgPg < pages) pgr += '<button type="button" class="chip sm" data-lgp="' + (lgPg + 1) + '">Seguinte ›</button>';
          pgr += '</nav>'; }
        rows = rows.slice((lgPg - 1) * 50, lgPg * 50);
        body.innerHTML = '<table class="list cards lg-tab"><colgroup><col style="width:160px"><col style="width:150px"><col><col style="width:140px"><col style="width:80px"><col style="width:90px"><col style="width:200px"></colgroup><thead><tr><th>Data</th><th>IP</th><th>Pedido</th><th>Código</th><th class="r">Tempo</th><th class="r">Tamanho</th><th>Navegador</th></tr></thead><tbody>' +
          rows.map(function (r) { return '<tr><td class="first mono" data-label="Data">' + fdate(r.t) + '</td><td class="mono" data-label="IP">' + esc(r.ip) + '</td><td data-label="Pedido" class="lg-cut" title="' + esc(r.m + ' ' + r.u) + '">' + (/\\x[0-9a-f]{2}/i.test(r.m + r.u) ? '<span class="mu">Pedido inválido (não é HTTP)</span>' : '<span class="mu">' + esc(r.m) + '</span> <span class="mono">' + esc(r.u) + '</span>') + '</td><td data-label="Código">' + pill(r.s) + (r.cs ? ' <span class="mu" title="Cache">' + esc(r.cs) + '</span>' : '') + '</td><td class="r" data-label="Tempo">' + (r.rt === null || r.rt === undefined ? '—' : '<span' + (r.rt >= 1 ? ' style="color:var(--err)"' : '') + '>' + Math.round(r.rt * 1000) + ' ms</span>') + '</td><td class="r" data-label="Tamanho">' + (r.b > 1024 ? Math.round(r.b / 1024) + ' KB' : r.b + ' B') + '</td><td class="mu lg-ua" title="' + esc(r.a) + '">' + esc(r.a) + '</td></tr>'; }).join('') + '</tbody></table>' + pgr;
      }).catch(function () { body.innerHTML = '<div class="empty">Não foi possível ler o log.</div>'; });
    } else {
      var f = t === 'php' ? 'php-error.log' : ('cron-' + (($('lg-cron') || {}).value || 'x') + '.log');
      fetch('/ficheiros/' + encodeURIComponent(site) + '/?a=tail&p=' + encodeURIComponent('logs/' + f) + '&n=' + n + '&q=' + encodeURIComponent(q), { credentials: 'same-origin', headers: { 'X-MP-Request': '1' } })
        .then(function (r) { return r.json(); }).then(function (d) { raw(d.lines || []); })
        .catch(function () { body.innerHTML = '<div class="empty">Não foi possível ler o log.</div>'; });
    }
  }
  var tm = null;
  body.addEventListener('click', function (e) { var b = e.target.closest('[data-lgp]'); if (!b) return; lgPg = +b.getAttribute('data-lgp'); load(); box.scrollIntoView({ block: 'start' }); });
  ['lg-n', 'lg-st', 'lg-cron'].forEach(function (id) { if ($(id)) $(id).addEventListener('change', function () { lgPg = 1; load(); }); });
  ['lg-q', 'lg-ip'].forEach(function (id) { if ($(id)) $(id).addEventListener('input', function () { clearTimeout(tm); tm = setTimeout(function () { lgPg = 1; load(); }, 400); }); });
  var live = null; $('lg-live').addEventListener('change', function (e) { if (e.target.checked) live = setInterval(load, 5000); else clearInterval(live); });
  load();
})();
</script>
<?php endif; ?>
<?php if ($page === 'processos'): ?>
<script>
(function () {
  var data = {}, page = 1, PER = 50, f = document.getElementById('pr-f'), q = document.getElementById('pr-q');
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function mb(kb) { return kb >= 1048576 ? (kb / 1048576).toFixed(1).replace('.', ',') + ' GB' : Math.round(kb / 1024) + ' MB'; }
  function ago(s) { return s >= 86400 ? Math.floor(s / 86400) + ' d' : s >= 3600 ? Math.floor(s / 3600) + ' h' : s >= 60 ? Math.floor(s / 60) + ' min' : s + ' s'; }
  var tone = { site: 'p-me', email: 'p-warn', bd: 'p-ok', web: 'p-off', painel: 'p-off', sistema: 'p-off' };
  function render() {
    var sum = data.sum || [], cpus = data.cpus || 1, memt = data.memt || 1, h = '';
    sum.slice(0, 12).forEach(function (s) {
      var c = Math.min(100, s.cpu / cpus), m = Math.min(100, s.rss * 100 / memt);
      h += '<div class="pr-o"><div class="nm"><span class="pill ' + (tone[s.t] || 'p-off') + '">' + esc(s.o) + '</span><span class="mu">' + s.n + ' proc.</span></div>' +
        '<div class="mu">CPU ' + c.toFixed(1).replace('.', ',') + '%</div><div class="cbar"><span style="width:' + c + '%"></span></div>' +
        '<div class="mu">RAM ' + mb(s.rss) + ' (' + m.toFixed(1).replace('.', ',') + '%)</div><div class="cbar"><span style="width:' + m + '%;background:var(--warn)"></span></div></div>';
    });
    document.getElementById('pr-sum').innerHTML = h || '<div class="empty">Sem dados (o recolhedor está a correr?).</div>';
    var rows = data.rows || [], fv = f.value, qv = (q.value || '').trim().toLowerCase();
    if (fv) rows = rows.filter(function (r) { return r.t === fv; });
    if (qv) rows = rows.filter(function (r) { return (r.args + ' ' + r.user + ' ' + r.pid + ' ' + r.o).toLowerCase().indexOf(qv) !== -1; });
    var pages = Math.max(1, Math.ceil(rows.length / PER)); if (page > pages) page = pages; h = '';
    rows.slice((page - 1) * PER, page * PER).forEach(function (r) {
      h += '<tr><td class="first mono" data-label="PID">' + r.pid + '</td><td data-label="Origem"><span class="pill ' + (tone[r.t] || 'p-off') + '">' + esc(r.o) + '</span><div class="mu">' + esc(r.user) + '</div></td>' +
        '<td class="r" data-label="CPU"><b' + (r.cpu >= 50 ? ' style="color:var(--err)"' : '') + '>' + r.cpu.toFixed(1).replace('.', ',') + '%</b></td>' +
        '<td class="r" data-label="Memória">' + mb(r.rss) + '<div class="mu">' + String(r.mem).replace('.', ',') + '%</div></td><td class="mu" data-label="Há" style="white-space:nowrap">' + ago(r.et) + '</td>' +
        '<td data-label="Comando"><div class="mono pr-cmd" title="' + esc(r.args) + '">' + esc(r.args) + '</div></td>' +
        '<td class="act r">' + (r.prot ? '<span class="mu">essencial</span>' : '<button class="btn sm danger-o" type="button" data-kill="' + r.pid + '">Terminar</button>') + '</td></tr>';
    });
    document.getElementById('pr-rows').innerHTML = h || '<tr><td colspan="7" class="empty">Nenhum processo com estes filtros.</td></tr>';
    var pg = ''; if (pages > 1) { pg += '<span class="mu">' + rows.length + ' processos</span>'; for (var i = 1; i <= pages; i++) if (i === 1 || i === pages || Math.abs(i - page) <= 2) pg += '<button type="button" class="chip sm' + (i === page ? ' prim' : '') + '" data-pg="' + i + '">' + i + '</button>'; }
    document.getElementById('pr-pager').innerHTML = pg;
    document.getElementById('pr-foot').textContent = data.ts ? 'Última leitura às ' + new Date(data.ts * 1000).toLocaleTimeString('pt-PT') + ' · ' + (data.rows || []).length + ' processos com mais consumo' : '';
  }
  document.addEventListener('click', function (e) {
    var p = e.target.closest('[data-pg]'); if (p) { page = +p.getAttribute('data-pg'); render(); return; }
    var k = e.target.closest('[data-kill]'); if (!k) return;
    var pid = +k.getAttribute('data-kill'), r = (data.rows || []).filter(function (x) { return x.pid === pid; })[0]; if (!r) return;
    document.getElementById('kill-pid').value = pid; document.getElementById('kill-t').textContent = pid;
    document.getElementById('kill-cmd').textContent = r.user + ': ' + r.args;
    document.getElementById('kill-site').innerHTML = r.site ? '<p class="mu" style="margin:6px 0 0">É do site <b>' + esc(r.site) + '</b>. <button class="lnk" type="button" data-killsite="' + esc(r.site) + '">Terminar todos os processos deste site</button></p>' : '';
    document.getElementById('dlg-kill').showModal();
  });
  document.addEventListener('click', function (e) {
    var s = e.target.closest('[data-killsite]'); if (!s) return;
    var fm = document.getElementById('kill-site-f'); document.getElementById('kill-site-n').value = s.getAttribute('data-killsite');
    fm.setAttribute('data-confirm', 'Terminar todos os processos do site ' + s.getAttribute('data-killsite') + '? O PHP do site volta a arrancar no próximo pedido.');
    document.getElementById('dlg-kill').close(); fm.requestSubmit();
  });
  f.addEventListener('change', function () { page = 1; render(); }); q.addEventListener('input', function () { page = 1; render(); });
  function poll() {
    fetch('?stats=procs', { credentials: 'same-origin', cache: 'no-store' }).then(function (r) { if (r.status === 401) { location.reload(); return null; } return r.json(); })
      .then(function (d) { if (d) { data = d; render(); } }).catch(function () {}).then(function () { setTimeout(poll, 10000); });
  }
  poll();
})();
</script>
<?php endif; ?>
<?php if ($page === 'dns'): ?>
<script>
(function () {
  var hints = {
    A: ['Endereço IPv4, ex.: 91.209.16.24', false], AAAA: ['Endereço IPv6, ex.: 2a01:4f8::1', false],
    CNAME: ['Outro nome, ex.: loja.exemplo.com (não pode ser usado no próprio domínio @)', false],
    MX: ['Servidor de email, ex.: host.iddigital.pt · prioridade: menor = preferido', true],
    TXT: ['Texto, ex.: v=spf1 mx ~all ou google-site-verification=…', false],
    SRV: ['peso porta destino, ex.: 5 5060 sip.exemplo.pt · prioridade em campo próprio', true],
    CAA: ['ex.: 0 issue "letsencrypt.org"', false], NS: ['Nameserver de um subdomínio, ex.: ns1.outro.pt', false]
  };
  function bindType(form) {
    var sel = form.querySelector('[data-rtype]'); if (!sel) return;
    function upd() { var hh = hints[sel.value] || ['', false]; var hEl = form.querySelector('[data-rhint]'); if (hEl) hEl.textContent = hh[0];
      var v = form.querySelector('[data-rval]'); if (v) v.placeholder = hh[0].replace(/^.*ex\.: /, '').split(' · ')[0];
      form.querySelectorAll('.dz-prio').forEach(function (p) { p.hidden = !hh[1]; }); }
    sel.addEventListener('change', upd); upd(); form._upd = upd;
  }
  document.querySelectorAll('#dz-add, #dlg-dr-edit form').forEach(bindType);
  var dlg = document.getElementById('dlg-dr-edit');
  document.addEventListener('click', function (e) {
    var b = e.target.closest('[data-edit]'); if (b && dlg) {
      var r = JSON.parse(b.getAttribute('data-edit')), f = dlg.querySelector('form');
      f.id.value = r.id; f.name.value = r.name; f.type.value = r.type; f.value.value = r.value; f.prio.value = r.prio || 10;
      f.ttl.value = [0, 300, 1800, 3600, 86400].indexOf(r.ttl) !== -1 ? String(r.ttl) : '0';
      dlg.querySelector('[data-edit-note]').textContent = r.id.indexOf('auto') === 0 ? 'Registo do painel: ao guardar, passa a manual e o painel deixa de o alterar.' : '';
      if (f._upd) f._upd(); dlg.showModal(); return;
    }
    var c = e.target.closest('[data-copy]'); if (c) { navigator.clipboard && navigator.clipboard.writeText(c.getAttribute('data-copy')); var t = c.textContent; c.textContent = 'Copiado'; setTimeout(function () { c.textContent = t; }, 1200); }
  });
  document.querySelectorAll('[data-secprov]').forEach(function (sel) { var f = sel.closest('form'); function upd() { f.classList.toggle('custom', sel.value === 'custom'); } sel.addEventListener('change', upd); upd(); });
  var ft = document.getElementById('dz-ft'), q = document.getElementById('dz-q');
  if (ft && q) {
    var rows = Array.prototype.slice.call(document.querySelectorAll('#dz-rows tr')), cnt = document.getElementById('dz-cnt');
    function filt() { var t = ft.value, v = q.value.trim().toLowerCase(), n = 0;
      rows.forEach(function (r) { var ok = (!t || r.getAttribute('data-type') === t) && (!v || r.getAttribute('data-s').toLowerCase().indexOf(v) !== -1); r.hidden = !ok; if (ok) n++; });
      cnt.textContent = n + ' de ' + rows.length + ' registos'; }
    ft.addEventListener('change', filt); q.addEventListener('input', filt); filt();
  }
})();
</script>
<?php endif; ?>
<?php if ($page === 'sentinela'): ?>
<script>
(function () {
  var box = document.getElementById('sn-all'); if (!box) return;
  var g = box.getAttribute('data-first'), q = document.getElementById('sn-q'), page = 1, PER = 50;
  var rows = Array.prototype.slice.call(document.querySelectorAll('#sn-rows tr'));
  function norm(s) { return s.toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, ''); }
  function render() {
    var v = norm(q.value.trim()), vis = rows.filter(function (r) { return (v ? true : r.getAttribute('data-g') === g) && (!v || norm(r.textContent).indexOf(v) !== -1); });
    var pages = Math.max(1, Math.ceil(vis.length / PER)); if (page > pages) page = pages;
    rows.forEach(function (r) { r.hidden = true; });
    vis.slice((page - 1) * PER, page * PER).forEach(function (r) { r.hidden = false; });
    var pg = ''; if (pages > 1) for (var i = 1; i <= pages; i++) pg += '<button type="button" class="chip sm' + (i === page ? ' prim' : '') + '" data-p="' + i + '">' + i + '</button>';
    document.getElementById('sn-pager').innerHTML = pg;
    document.getElementById('sn-foot').textContent = v ? vis.length + ' testes encontrados em todos os grupos' : vis.length + ' testes em ' + g;
    document.querySelectorAll('.sn-tabs [data-g]').forEach(function (b) { b.classList.toggle('prim', !v && b.getAttribute('data-g') === g); });
  }
  box.addEventListener('click', function (e) {
    var b = e.target.closest('[data-g]'); if (b && b.tagName === 'BUTTON') { g = b.getAttribute('data-g'); q.value = ''; page = 1; render(); return; }
    var p = e.target.closest('[data-p]'); if (p) { page = +p.getAttribute('data-p'); render(); }
  });
  q.addEventListener('input', function () { page = 1; render(); });
  render();
})();
</script>
<?php endif; ?>
<?php if ($page === 'manual'): ?>
<script>
(function () {
  var q = document.getElementById('md-q'); if (!q) return;
  var secs = Array.prototype.slice.call(document.querySelectorAll('.md-sec')), nav = document.querySelectorAll('.md-nav a'), none = document.getElementById('md-none');
  function norm(s) { return s.toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, ''); }
  var texts = secs.map(function (s) { return norm(s.textContent); });
  q.addEventListener('input', function () {
    var v = norm(q.value.trim()), shown = 0;
    secs.forEach(function (s, i) { var ok = !v || texts[i].indexOf(v) !== -1; s.hidden = !ok; if (ok) shown++; });
    nav.forEach(function (a) { var id = a.getAttribute('data-sec') || a.getAttribute('href').slice(1); var s = document.getElementById(id); a.hidden = !!(s && s.hidden); });
    none.hidden = shown > 0;
  });
  // destaca no índice a secção que está no ecrã
  if ('IntersectionObserver' in window) {
    var io = new IntersectionObserver(function (es) { es.forEach(function (e) { if (e.isIntersecting) { nav.forEach(function (a) { a.classList.toggle('on', a.getAttribute('href') === '#' + e.target.id); }); } }); }, { rootMargin: '-20% 0px -70% 0px' });
    secs.forEach(function (s) { io.observe(s); });
  }
})();
</script>
<?php endif; ?>
<?php if ($page === 'terminal'): ?>
<script>
(function () { var f = document.getElementById('term'); if (!f) return; var w = document.getElementById('term-wait'), src = f.getAttribute('data-src'), n = 0;
  function tick() { fetch(src, { credentials: 'same-origin', cache: 'no-store' }).then(function (r) {
      if (r.ok) { f.src = src; w.style.display = 'none'; f.style.display = 'block'; return; }
      // sem resposta durante 15 s: o terminal desta sessão já terminou (página recarregada, exit ou inatividade)
      if (++n >= 15) { location.href = '?term=reset'; return; } setTimeout(tick, 1000); })
    .catch(function () { if (++n >= 15) { location.href = '?term=reset'; return; } setTimeout(tick, 1000); }); }
  tick(); })();
</script>
<?php endif; ?>
<?php if ($page === 'atualizacoes'): ?>
<script>
(function () { function tick() { if (document.querySelector('dialog[open]')) setTimeout(tick, 5000); else location.reload(); }
  if (document.querySelector('[data-bk-running]')) setTimeout(tick, 5000); })();
</script>
<?php endif; ?>
<?php if ($page === 'backups'): ?>
<script>
(function () {
  var t = document.getElementById('rm-type');
  if (t) {
    var sw = function () { document.querySelectorAll('.rm-grp').forEach(function (g) { g.hidden = g.getAttribute('data-rm') !== t.value; }); };
    t.addEventListener('change', sw); sw();
  }
  function tick() { if (document.querySelector("dialog[open]")) setTimeout(tick, 5000); else location.reload(); }
  if (document.querySelector("[data-bk-running]")) setTimeout(tick, 5000);
})();
</script>
<?php endif; ?>
<?php if ($page === 'cron'): ?>
<script>
(function () {
  var dlg = document.getElementById('dlg-cron'); if (!dlg) return;
  var F = [0, 1, 2, 3, 4].map(function (i) { return document.getElementById('cf-' + i); });
  var human = document.getElementById('cron-human'), when = document.getElementById('cron-when'), cmd = document.getElementById('cron-cmd');
  var site = document.getElementById('cron-site');
  var days = ['domingo', 'segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado', 'domingo'];
  function two(n) { return (n < 10 ? '0' : '') + n; }
  function desc(p) {
    var mi = p[0], ho = p[1], dm = p[2], mo = p[3], dw = p[4], n = /^\d+$/, m;
    var hm = function () { return two(+ho) + ':' + two(+mi); };
    if (dm === '*' && mo === '*' && dw === '*') {
      if (mi === '*' && ho === '*') return 'A cada minuto';
      if ((m = /^\*\/(\d+)$/.exec(mi)) && ho === '*') return 'A cada ' + m[1] + ' minutos';
      if (n.test(mi) && ho === '*') return 'De hora a hora, ao minuto ' + (+mi);
      if (n.test(mi) && (m = /^\*\/(\d+)$/.exec(ho))) return 'A cada ' + m[1] + ' horas, ao minuto ' + (+mi);
      if (n.test(mi) && n.test(ho)) return 'Todos os dias às ' + hm();
    }
    if (n.test(mi) && n.test(ho) && dm === '*' && mo === '*') {
      if (/^[0-7]$/.test(dw)) return 'À ' + days[+dw] + ' às ' + hm();
      if (dw === '1-5') return 'Dias úteis às ' + hm();
    }
    if (n.test(mi) && n.test(ho) && n.test(dm) && mo === '*' && dw === '*') return 'No dia ' + (+dm) + ' de cada mês às ' + hm();
    return 'Expressão personalizada';
  }
  function sync() {
    var p = F.map(function (f) { return f.value.trim() || '*'; });
    var ok = p.every(function (x) { return /^(\*|[0-9A-Za-z]+(-[0-9A-Za-z]+)?)(\/[0-9]+)?(,(\*|[0-9A-Za-z]+(-[0-9A-Za-z]+)?)(\/[0-9]+)?)*$/.test(x); });
    when.value = p.join(' ');
    human.textContent = ok ? desc(p) + '  ·  ' + when.value : 'Expressão inválida';
    human.classList.toggle('bad', !ok);
  }
  F.forEach(function (f) { f.addEventListener('input', sync); });
  document.getElementById('cron-preset').addEventListener('change', function (e) {
    if (!e.target.value) return; e.target.value.split(' ').forEach(function (v, i) { F[i].value = v; }); sync();
  });
  function ins(t) { var s = cmd.selectionStart, v = cmd.value; cmd.value = v.slice(0, s) + t + v.slice(cmd.selectionEnd); cmd.focus(); cmd.selectionStart = cmd.selectionEnd = s + t.length; }
  document.querySelector('.cron-help').addEventListener('click', function (e) {
    var b = e.target.closest('[data-ins]'); if (!b) return;
    var sn = site.value, port = site.options[site.selectedIndex].getAttribute('data-port');
    var k = b.getAttribute('data-ins');
    if (k === 'php') ins('php /srv/www/' + sn + '/public_html/');
    else if (k === 'url') ins('curl -fsS -m 300 "http://127.0.0.1' + (port === '80' ? '' : ':' + port) + '/"');
    else ins(' >/dev/null 2>&1');
  });
  function open(d) {
    document.getElementById('t-cron').textContent = d ? 'Editar tarefa agendada' : 'Nova tarefa agendada';
    document.getElementById('cron-submit').textContent = d ? 'Guardar alterações' : 'Criar tarefa';
    document.getElementById('cron-id').value = d ? d.id : '';
    if (d) { site.value = d.site; cmd.value = d.cmd; document.getElementById('cron-desc').value = d.desc || ''; var w = d.when.split(/\s+/); if (w.length === 5) w.forEach(function (v, i) { F[i].value = v; }); }
    else { cmd.value = ''; document.getElementById('cron-desc').value = ''; ['*/5', '*', '*', '*', '*'].forEach(function (v, i) { F[i].value = v; }); }
    site.disabled = !!d;
    document.getElementById('cron-preset').value = ''; sync(); dlg.showModal(); cmd.focus();
  }
  document.addEventListener('click', function (e) {
    var b = e.target.closest('[data-cron-new]'); if (b) { e.preventDefault(); open(null); return; }
    b = e.target.closest('[data-cron-edit]'); if (b) { e.preventDefault(); open(JSON.parse(b.getAttribute('data-cron-edit'))); }
  });
  document.getElementById('cron-form').addEventListener('submit', function (e) {
    sync(); if (human.classList.contains('bad')) { e.preventDefault(); return; }
    if (cmd.value.indexOf('\n') !== -1) cmd.value = cmd.value.replace(/[\r\n]+/g, ' ');
    site.disabled = false;
  });
  sync();
})();
</script>
<?php endif; ?>
<?php if ($page === 'ligacoes'): ?>
<script>
(function () {
  var box = document.getElementById('cn'); if (!box) return;
  var mode = box.getAttribute('data-mode');
  var L = JSON.parse(box.getAttribute('data-labels') || '{}'), allow = JSON.parse(box.getAttribute('data-allow') || '[]');
  var me = box.getAttribute('data-me'), lim = +box.getAttribute('data-limit') || 0, auto = box.getAttribute('data-auto') === '1';
  var home = box.getAttribute('data-home') || '', blocked = JSON.parse(box.getAttribute('data-blocked') || '[]');
  var data = {}, q = document.getElementById('cn-q'), page = 1, PER = 50;
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function lab(p) { return L[p] ? L[p] + ' :' + p : ':' + p; }
  function stats() {
    document.querySelectorAll('[data-c]').forEach(function (e) { var k = e.getAttribute('data-c'); if (data[k] !== undefined) e.textContent = data[k]; });
  }
  function renderIp() {
    var rows = (data.ips || []), f = (q.value || '').trim().toLowerCase(), h = '';
    if (f) rows = rows.filter(function (r) { return r.ip.indexOf(f) !== -1 || (r.cn || '').toLowerCase().indexOf(f) !== -1 || (r.cc || '').toLowerCase() === f; });
    var pages = Math.max(1, Math.ceil(rows.length / PER)); if (page > pages) page = pages;
    rows.slice((page - 1) * PER, page * PER).forEach(function (r) {
      var ports = Object.keys(r.ports || {}).sort(function (a, b) { return r.ports[b] - r.ports[a]; }).map(function (p) { return esc(lab(p)) + ' (' + r.ports[p] + ')'; }).join(' · ');
      var isMe = r.ip === me, ok = allow.indexOf(r.ip) !== -1, hot = lim && r.n >= lim * 0.8;
      var act = isMe ? '<span class="mu">protegido</span>' : ok ? '<span class="mu">confiança</span>' : '<button class="btn sm danger-o" type="button" data-block="' + esc(r.ip) + '">Bloquear</button>';
      h += '<tr><td class="first" data-label="IP"><span class="nm mono">' + esc(r.ip) + '</span>' + (isMe ? ' <span class="pill p-me">tu</span>' : '') + (r.syn ? '<div class="mu">' + r.syn + ' em espera (SYN)</div>' : '') + '</td>' +
        '<td data-label="País"><span class="cc-flag">' + esc(r.fl || '') + '</span> ' + esc(r.cn || '') + '</td>' +
        '<td class="r" data-label="Ligações"><b class="' + (hot ? 'cn-hot' : '') + '">' + r.n + '</b></td><td class="mu" data-label="Destino">' + ports + '</td><td class="act r">' + act + '</td></tr>';
    });
    if (!h) h = '<tr><td colspan="5" class="empty">' + (f ? 'Nada corresponde à pesquisa.' : 'Sem ligações abertas de momento.') + '</td></tr>';
    document.getElementById('cn-rows').innerHTML = h;
    var pg = ''; if (pages > 1) { pg += '<span class="mu">' + rows.length + ' IPs</span>'; for (var i = 1; i <= pages; i++) if (i === 1 || i === pages || Math.abs(i - page) <= 2) pg += '<button type="button" class="chip sm' + (i === page ? ' prim' : '') + '" data-pg="' + i + '">' + i + '</button>'; }
    document.getElementById('cn-pager').innerHTML = pg;
    var t = data.ts ? new Date(data.ts * 1000) : null;
    document.getElementById('cn-foot').textContent = (auto ? 'Bloqueio automático acima de ' + lim + ' ligações por IP. ' : '') + (t ? 'Última leitura às ' + t.toLocaleTimeString('pt-PT') + '.' : '');
  }
  function renderCc() {
    var rows = data.countries || [], tot = rows.reduce(function (a, r) { return a + r.n; }, 0) || 1, h = '';
    rows.slice(0, 40).forEach(function (r) {
      var pc = Math.round(r.n * 100 / tot), canBlock = r.cc && r.cc !== home && blocked.indexOf(r.cc) === -1;
      h += '<div class="item"><span class="cc-flag">' + esc(r.fl) + '</span><div class="grow"><div class="nm">' + esc(r.cn) + (r.cc === home ? ' <span class="pill p-ok">país do servidor</span>' : '') + '</div>' +
        '<div class="cbar"><span style="width:' + pc + '%"></span></div><div class="mu">' + r.n + ' ligações · ' + r.ips + ' IPs · ' + pc + '%</div></div>' +
        (canBlock ? '<button class="btn sm danger-o" type="button" data-cc="' + esc(r.cc) + '">Bloquear</button>' : '') + '</div>';
    });
    document.getElementById('cc-rows').innerHTML = h || '<div class="empty">Sem ligações abertas de momento.</div>';
  }
  function render() { stats(); if (mode === 'cc') renderCc(); else renderIp(); }
  document.addEventListener('click', function (e) {
    var b = e.target.closest('[data-block]');
    if (b) { document.getElementById('blk-ip').value = b.getAttribute('data-block'); document.getElementById('dlg-block').showModal(); return; }
    var p = e.target.closest('[data-pg]'); if (p) { page = +p.getAttribute('data-pg'); renderIp(); return; }
    var c = e.target.closest('[data-cc]');
    if (c) { var sel = document.querySelector('select[name=cc]'); if (sel) { sel.value = c.getAttribute('data-cc'); sel.form.requestSubmit(); } }
  });
  if (q) q.addEventListener('input', function () { page = 1; renderIp(); });
  function poll() {
    fetch('?stats=conns', { credentials: 'same-origin', cache: 'no-store' })
      .then(function (r) { if (r.status === 401) { location.reload(); return null; } return r.json(); })
      .then(function (d) { if (d && d.ts) { data = d; render(); } })
      .catch(function () {}).then(function () { setTimeout(poll, 5000); });
  }
  poll();
})();
</script>
<?php endif; ?>
<?php if ($page === 'recursos' || $page === 'resumo'): ?>
<script>
(function () {
  function dec(v, d) { return Number(v || 0).toFixed(d === undefined ? 1 : d).replace('.', ','); }
  function bytes(b) { var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0; b = Number(b || 0); while (b >= 1024 && i < 4) { b /= 1024; i++; } return (i ? b.toFixed(1).replace('.', ',') : Math.round(b)) + ' ' + u[i]; }
  function bps(b) { var u = ['b/s', 'Kb/s', 'Mb/s', 'Gb/s'], i = 0; b = Number(b || 0); while (b >= 1000 && i < 3) { b /= 1000; i++; } return (i ? b.toFixed(1).replace('.', ',') : Math.round(b)) + ' ' + u[i]; }
  function fmt(v, f) { return f === 'pct' ? dec(v) + '%' : f === 'bps' ? bps(v) : dec(v, 2); }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function set(k, t) { document.querySelectorAll('[data-l="' + k + '"]').forEach(function (e) { e.textContent = t; }); }
  function bar(k, v) { document.querySelectorAll('[data-lm="' + k + '"]').forEach(function (e) { e.style.width = Math.max(0, Math.min(100, v)) + '%'; e.classList.toggle('hi', v >= 90); }); }
  function upd() {
    fetch('?stats=live', { credentials: 'same-origin', cache: 'no-store' })
      .then(function (r) { if (r.status === 401) { location.reload(); return null; } return r.json(); })
      .then(function (d) {
        if (!d || !d.ts) return;
        set('cpu', dec(d.cpu) + '%'); bar('cpu', d.cpu);
        set('mem', dec(d.mem.pct) + '%'); set('mem-sub', bytes(d.mem.used * 1024) + ' / ' + bytes(d.mem.total * 1024)); bar('mem', d.mem.pct);
        set('disk', dec(d.disk.pct) + '%'); set('disk-sub', bytes(d.disk.used * 1024) + ' / ' + bytes(d.disk.total * 1024)); bar('disk', d.disk.pct);
        set('load', dec(d.load[0], 2)); set('load-sub', '5 min ' + dec(d.load[1], 2) + ' · 15 min ' + dec(d.load[2], 2));
        set('swap', 'Swap ' + dec(d.swap.pct) + '%');
        set('net', bps(d.net.rx + d.net.tx)); set('net-sub', '↓ ' + bps(d.net.rx) + ' · ↑ ' + bps(d.net.tx));
        document.querySelectorAll('[data-ls]').forEach(function (e) {
          var p = e.getAttribute('data-ls').split(':'), s = (d.sites || {})[p[0]] || { cpu: 0, rss: 0 };
          e.textContent = p[1] === 'cpu' ? dec(s.cpu) + '%' : bytes(s.rss * 1024);
        });
      })
      .catch(function () {})
      .then(function () { setTimeout(upd, 5000); });
  }
  if (document.querySelector('[data-live]')) setTimeout(upd, 5000);

  document.querySelectorAll('.chart').forEach(function (c) {
    var d; try { d = JSON.parse(c.getAttribute('data-chart')); } catch (e) { return; }
    if (!d.t || d.t.length < 2) return;
    var plot = c.querySelector('.ch-plot'), cur = c.querySelector('.ch-cur'), tip = c.querySelector('.ch-tip');
    function two(n) { return (n < 10 ? '0' : '') + n; }
    plot.addEventListener('mousemove', function (e) {
      var r = plot.getBoundingClientRect(), t = d.from + (d.to - d.from) * ((e.clientX - r.left) / r.width);
      var lo = 0, hi = d.t.length - 1;
      while (hi - lo > 1) { var mid = (lo + hi) >> 1; if (d.t[mid] < t) lo = mid; else hi = mid; }
      var i = Math.abs(d.t[lo] - t) <= Math.abs(d.t[hi] - t) ? lo : hi;
      var x = (d.t[i] - d.from) / (d.to - d.from) * 100;
      cur.style.left = x + '%'; cur.style.display = 'block';
      var dt = new Date((d.t[i] + d.tz) * 1000);
      var lab = two(dt.getUTCDate()) + '/' + two(dt.getUTCMonth() + 1) + ' ' + two(dt.getUTCHours()) + ':' + two(dt.getUTCMinutes());
      tip.innerHTML = '<b>' + lab + '</b>' + d.s.map(function (s) { return '<div><i style="background:' + esc(s.c) + '"></i>' + esc(s.n) + ': ' + fmt(s.v[i], d.fmt) + '</div>'; }).join('');
      tip.style.display = 'block';
      if (x > 60) { tip.style.left = ''; tip.style.right = (100 - x) + '%'; } else { tip.style.right = ''; tip.style.left = x + '%'; }
    });
    plot.addEventListener('mouseleave', function () { cur.style.display = 'none'; tip.style.display = 'none'; });
  });
})();
</script>
<?php endif; ?>
<?php if ($page === 'ficheiros' && !empty($fmSite)): ?>
<script>
(function () {
  var root = document.getElementById('fm'); if (!root) return;
  var IC = <?= json_encode(['dir' => ic('folder', 'dir'), 'zip' => ic('zip', 'zip'), 'code' => ic('code', 'code'), 'file' => ic('file', 'file'), 'up' => ic('up', 'file'), 'dots' => ic('dots'), 'home' => ic('home'), 'open' => ic('folder'), 'dl' => ic('download'), 'edit' => ic('edit'), 'ren' => ic('edit'), 'move' => ic('move'), 'zipb' => ic('zip'), 'perm' => ic('lock'), 'del' => ic('trash'), 'x' => ic('x')], JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT) ?>;
  var $ = function (id) { return document.getElementById(id); };
  var st = { site: root.getAttribute('data-site'), path: '', items: [], sel: {} };
  var NOEDIT = root.getAttribute('data-noedit') === '1', LABEL = root.getAttribute('data-label') || st.site;
  var EDIT = /(\.(php|phtml|inc|html?|css|scss|js|mjs|json|txt|md|xml|svg|ini|conf|env|log|csv|sql|ya?ml|twig|tpl|sh|py|htaccess|htpasswd|user\.ini)|^\.[a-z]+)$/i;
  var ARCH = /\.(zip|tar|tgz|tar\.gz|tar\.bz2)$/i;
  var CH = 8 * 1024 * 1024;

  function base(site) { return '/ficheiros/' + encodeURIComponent(site || st.site) + '/'; }
  function join(a, b) { return a ? (b ? a + '/' + b : a) : b; }
  function enc(s) { return encodeURIComponent(s); }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function bytes(b) { if (b === null || b === undefined) return '—'; var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0; b = Number(b); while (b >= 1024 && i < 4) { b /= 1024; i++; } return (i ? b.toFixed(1).replace('.', ',') : b) + ' ' + u[i]; }
  function two(n) { return (n < 10 ? '0' : '') + n; }
  function when(t) { var d = new Date(t * 1000); return two(d.getDate()) + '/' + two(d.getMonth() + 1) + '/' + d.getFullYear() + ' ' + two(d.getHours()) + ':' + two(d.getMinutes()); }
  function toast(ok, msg) {
    var box = document.querySelector('.toasts'); if (!box) return;
    var t = document.createElement('div'); t.className = 'toast ' + (ok ? 'ok' : 'err');
    t.innerHTML = '<span class="ti">' + (ok ? '✓' : '!') + '</span><div class="msg"></div><button type="button" data-dismiss aria-label="Fechar">' + IC.x + '</button>';
    t.querySelector('.msg').textContent = msg; box.appendChild(t);
    if (ok) setTimeout(function () { t.remove(); }, 5000);
  }
  function api(a, data, q, site) {
    var init = { credentials: 'same-origin', headers: { 'X-MP-Request': '1' }, cache: 'no-store' };
    if (data instanceof FormData) { init.method = 'POST'; init.body = data; }
    else if (data) { init.method = 'POST'; init.headers['Content-Type'] = 'application/json'; init.body = JSON.stringify(data); }
    return fetch(base(site) + '?a=' + a + (q ? '&' + q : ''), init).then(function (r) {
      if (r.redirected && r.url.indexOf('/ficheiros/') === -1) { location.reload(); throw new Error('A sessão expirou.'); }
      return r.json().catch(function () { throw new Error('Resposta inválida do servidor (' + r.status + ').'); })
        .then(function (j) { j._s = r.status; return j; });
    });
  }
  function must(j) { if (!j.ok) { var e = new Error(j.error || 'Falhou.'); e.j = j; throw e; } return j; }
  function fail(e) { toast(false, e.message || String(e)); }

  /* ---------- diálogo ---------- */
  function ask(title, msg, value, okLabel, danger) {
    var d = $('fm-dlg'), inp = $('fm-dlg-in'), ok = $('fm-dlg-ok');
    $('fm-dlg-t').textContent = title; $('fm-dlg-msg').textContent = msg || '';
    $('fm-dlg-msg').hidden = !msg;
    inp.hidden = value === null; inp.value = value === null ? '' : value;
    ok.textContent = okLabel || 'OK'; ok.className = 'btn' + (danger ? ' dan' : '');
    d.returnValue = ''; d.showModal();
    if (value !== null) { inp.focus(); var dot = inp.value.lastIndexOf('.'); inp.setSelectionRange(0, dot > 0 ? dot : inp.value.length); } else ok.focus();
    return new Promise(function (res) {
      d.addEventListener('close', function h() { d.removeEventListener('close', h); res(d.returnValue === 'ok' ? (value === null ? true : inp.value.trim()) : null); });
    });
  }

  /* ---------- listagem ---------- */
  function setUrl() { var u = '?p=ficheiros&site=' + enc(st.site) + (st.path ? '&dir=' + enc(st.path) : ''); history.replaceState(null, '', u); }
  function load(path) {
    if (path !== undefined) { st.path = path; st.sel = {}; }
    return api('list', null, 'p=' + enc(st.path)).then(must).then(function (j) {
      st.items = j.items; render(j.free);
    }).catch(function (e) {
      if (st.path) { toast(false, e.message); st.path = ''; return load(); }
      $('fm-rows').innerHTML = '<tr><td colspan="5" class="empty"></td></tr>';
      $('fm-rows').querySelector('td').textContent = e.message;
    }).then(setUrl);
  }
  function kind(it) { return it.d ? 'dir' : ARCH.test(it.n) ? 'zip' : EDIT.test(it.n) ? 'code' : 'file'; }
  function render(free) {
    var tb = $('fm-rows'), h = '';
    if (st.path) h += '<tr data-up="1"><td class="first" colspan="5"><button type="button" class="fm-name" data-act="up">' + IC.up + '<span>.. (pasta acima)</span></button></td></tr>';
    st.items.forEach(function (it, i) {
      h += '<tr data-i="' + i + '"' + (st.sel[it.n] ? ' class="sel"' : '') + '>' +
        '<td class="first" data-label="Nome"><div class="fm-first"><label class="fm-ck"><input type="checkbox"' + (st.sel[it.n] ? ' checked' : '') + ' aria-label="Selecionar ' + esc(it.n) + '"></label>' +
        '<button type="button" class="fm-name" data-act="open">' + IC[kind(it)] + '<span>' + esc(it.n) + (it.l ? ' ↪' : '') + '</span></button></div></td>' +
        '<td class="r mu" data-label="Tamanho">' + (it.d ? '—' : bytes(it.s)) + '</td>' +
        '<td class="mu" data-label="Modificado">' + when(it.m) + '</td>' +
        '<td class="mono mu" data-label="Permissões">' + esc(it.p.replace(/^0(?=\d{3}$)/, '')) + '</td>' +
        '<td class="act r"><button type="button" class="iconbtn" data-act="menu" aria-label="Ações de ' + esc(it.n) + '">' + IC.dots + '</button></td></tr>';
    });
    if (!st.items.length) h += '<tr><td colspan="5" class="empty">Pasta vazia. Arrasta ficheiros para aqui ou usa “Enviar ficheiros”.</td></tr>';
    tb.innerHTML = h;
    crumbs(); selbar();
    var nd = st.items.filter(function (i) { return i.d; }).length;
    $('fm-foot').textContent = nd + ' pasta(s), ' + (st.items.length - nd) + ' ficheiro(s)' + (free ? ' · ' + bytes(free) + ' livres no disco' : '') + ' · arrasta ficheiros ou pastas para a lista para os enviar';
  }
  function crumbs() {
    var c = $('fm-crumbs'), parts = st.path ? st.path.split('/') : [], h = '<button type="button" data-path="">' + esc(LABEL) + '</button>';
    parts.forEach(function (p, i) { h += '<span class="sep">/</span><button type="button" data-path="' + esc(parts.slice(0, i + 1).join('/')) + '">' + esc(p) + '</button>'; });
    c.innerHTML = h;
  }
  function selected() { return Object.keys(st.sel); }
  function selbar() {
    var n = selected().length;
    $('fm-selbar').hidden = n === 0;
    $('fm-selcount').textContent = n === 1 ? '1 item selecionado' : n + ' itens selecionados';
    $('fm-all').checked = n > 0 && n === st.items.length;
  }

  /* ---------- ações ---------- */
  function done(msg) { return function (j) { must(j); if (msg) toast(true, typeof msg === 'function' ? msg(j) : msg); return load(); }; }
  function download(it) {
    var a = document.createElement('a'); a.href = base() + '?a=dl&p=' + enc(join(st.path, it.n)); a.download = it.n;
    document.body.appendChild(a); a.click(); a.remove();
  }
  function open(it) {
    if (it.d) return load(join(st.path, it.n));
    if (!NOEDIT && (EDIT.test(it.n) || it.s < 2097152 && !ARCH.test(it.n) && it.n.indexOf('.') === -1)) return edit(join(st.path, it.n));
    download(it);
  }
  function act(name, items) {
    var p = st.path;
    if (name === 'mkdir' || name === 'newfile') {
      return ask(name === 'mkdir' ? 'Nova pasta' : 'Novo ficheiro', 'Em /' + p, '', 'Criar').then(function (v) {
        if (!v) return;
        return api(name, { p: p, name: v }).then(must).then(function () {
          return load().then(function () { if (name === 'newfile') edit(join(p, v)); });
        });
      }).catch(fail);
    }
    if (!items.length) return;
    var one = items.length === 1 ? items[0] : null;
    var label = one ? '“' + one + '”' : items.length + ' itens';
    if (name === 'rename') {
      return ask('Mudar o nome', null, one, 'Mudar nome').then(function (v) { if (!v || v === one) return; return api('rename', { p: p, from: one, to: v }).then(done('Nome alterado.')); }).catch(fail);
    }
    if (name === 'move') {
      return ask('Mover ' + label, 'Pasta de destino, a partir da raiz do site (ex.: public_html/img). Vazio = raiz do site.', p, 'Mover').then(function (v) {
        if (v === null) return; return api('move', { p: p, items: items, to: v }).then(done('Movido para /' + v + '.'));
      }).catch(fail);
    }
    if (name === 'zip') {
      return ask('Compactar ' + label, 'Nome do ficheiro ZIP, criado nesta pasta.', (one || 'arquivo') + '.zip', 'Compactar').then(function (v) {
        if (!v) return; toast(true, 'A compactar…'); return api('zip', { p: p, items: items, name: v }).then(done(function (j) { return 'Criado ' + j.name + ' (' + j.count + ' ficheiros).'; }));
      }).catch(fail);
    }
    if (name === 'chmod') {
      var cur = one ? (st.items.filter(function (i) { return i.n === one; })[0] || {}).p : '';
      return ask('Permissões de ' + label, 'Em octal, por exemplo 640 para ficheiros e 2750 para pastas.', (cur || '640').replace(/^0(?=\d{3}$)/, ''), 'Aplicar').then(function (v) {
        if (!v) return; return api('chmod', { p: p, items: items, mode: v }).then(done('Permissões alteradas.'));
      }).catch(fail);
    }
    if (name === 'delete') {
      return ask('Apagar ' + label + '?', 'As pastas são apagadas com todo o conteúdo. Esta ação não pode ser anulada.', null, 'Apagar', true).then(function (ok) {
        if (!ok) return; return api('delete', { p: p, items: items }).then(done(items.length === 1 ? 'Apagado.' : items.length + ' itens apagados.'));
      }).catch(fail);
    }
    if (name === 'extract' || name === 'extractto') {
      var into = name === 'extractto' ? ask('Extrair para uma pasta', 'Nome da pasta a criar nesta localização.', one.replace(ARCH, ''), 'Extrair') : Promise.resolve('');
      return into.then(function (v) {
        if (v === null) return; toast(true, 'A extrair ' + one + '…');
        return api('extract', { p: join(p, one), into: v }).then(done(function (j) { return j.count + ' ficheiro(s) extraído(s)' + (j.skipped ? '; ' + j.skipped + ' ignorado(s) por segurança' : '') + '.'; }));
      }).catch(fail);
    }
  }

  /* ---------- menu de cada item ---------- */
  var menu = $('fm-menu');
  function hideMenu() { menu.hidden = true; }
  function showMenu(it, btn) {
    var o = [];
    if (it.d) o.push(['open', IC.open, 'Abrir']); else o.push(['dl', IC.dl, 'Descarregar']);
    if (!NOEDIT && !it.d && (EDIT.test(it.n) || it.s < 2097152 && !ARCH.test(it.n))) o.push(['edit', IC.edit, 'Editar']);
    if (ARCH.test(it.n)) { o.push(['extract', IC.zipb, 'Extrair aqui']); o.push(['extractto', IC.zipb, 'Extrair para pasta…']); }
    o.push(['rename', IC.ren, 'Mudar o nome'], ['move', IC.move, 'Mover…'], ['zip', IC.zipb, 'Compactar em ZIP'], ['chmod', IC.perm, 'Permissões'], ['-'], ['delete', IC.del, 'Apagar']);
    menu.innerHTML = o.map(function (x) { return x[0] === '-' ? '<hr>' : '<button type="button" data-m="' + x[0] + '"' + (x[0] === 'delete' ? ' class="dan"' : '') + '>' + x[1] + x[2] + '</button>'; }).join('');
    menu.hidden = false;
    var r = btn.getBoundingClientRect(), mh = menu.offsetHeight, mw = menu.offsetWidth;
    menu.style.left = Math.max(8, Math.min(window.innerWidth - mw - 8, r.right - mw)) + 'px';
    menu.style.top = (r.bottom + mh + 8 > window.innerHeight ? Math.max(8, r.top - mh - 6) : r.bottom + 6) + 'px';
    menu.onclick = function (e) {
      var b = e.target.closest('[data-m]'); if (!b) return; hideMenu();
      var m = b.getAttribute('data-m');
      if (m === 'open') load(join(st.path, it.n));
      else if (m === 'dl') download(it);
      else if (m === 'edit') edit(join(st.path, it.n));
      else act(m, [it.n]);
    };
  }
  document.addEventListener('click', function (e) { if (!menu.hidden && !e.target.closest('#fm-menu') && !e.target.closest('[data-act="menu"]')) hideMenu(); });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') hideMenu(); });
  window.addEventListener('scroll', hideMenu, true);

  $('fm-rows').addEventListener('click', function (e) {
    var tr = e.target.closest('tr'); if (!tr) return;
    if (tr.getAttribute('data-up')) { var parts = st.path.split('/'); parts.pop(); load(parts.join('/')); return; }
    var it = st.items[+tr.getAttribute('data-i')]; if (!it) return;
    var b = e.target.closest('[data-act]');
    if (b && b.getAttribute('data-act') === 'open') open(it);
    else if (b && b.getAttribute('data-act') === 'menu') { e.stopPropagation(); if (!menu.hidden) hideMenu(); else showMenu(it, b); }
  });
  $('fm-rows').addEventListener('change', function (e) {
    var tr = e.target.closest('tr'); var it = tr && st.items[+tr.getAttribute('data-i')]; if (!it) return;
    if (e.target.checked) st.sel[it.n] = 1; else delete st.sel[it.n];
    tr.classList.toggle('sel', e.target.checked); selbar();
  });
  $('fm-all').addEventListener('change', function (e) { st.sel = {}; if (e.target.checked) st.items.forEach(function (i) { st.sel[i.n] = 1; }); render(); });
  $('fm-crumbs').addEventListener('click', function (e) { var b = e.target.closest('[data-path]'); if (b) load(b.getAttribute('data-path')); });
  if ($('fm-site')) $('fm-site').addEventListener('change', function (e) { st.site = e.target.value; load(''); });
  root.addEventListener('click', function (e) {
    var b = e.target.closest('[data-fm]'); if (!b) return;
    var n = b.getAttribute('data-fm');
    if (n === 'clear') { st.sel = {}; render(); return; }
    act(n, n === 'mkdir' || n === 'newfile' ? [] : selected());
  });

  /* ---------- editor ---------- */
  var ed = { path: null, dirty: false }, ta = $('fm-ed-ta'), edDlg = $('fm-ed');
  function edStatus(t) { $('fm-ed-st').textContent = t; }
  function edit(rel) {
    api('get', null, 'p=' + enc(rel)).then(must).then(function (j) {
      ed.path = rel; ed.dirty = false; ta.value = j.content; $('fm-ed-t').textContent = '/' + rel; edStatus('');
      edDlg.showModal(); ta.focus(); ta.setSelectionRange(0, 0); ta.scrollTop = 0;
    }).catch(fail);
  }
  function save() {
    if (!ed.path) return;
    edStatus('A gravar…');
    api('save', { p: ed.path, content: ta.value }).then(must).then(function () {
      ed.dirty = false; var d = new Date(); edStatus('Gravado às ' + two(d.getHours()) + ':' + two(d.getMinutes()) + ':' + two(d.getSeconds()));
      load();
    }).catch(function (e) { edStatus(''); fail(e); });
  }
  function edClose() { if (ed.dirty && !window.confirm('Há alterações por gravar. Fechar sem gravar?')) return; ed.dirty = false; edDlg.close(); }
  ta.addEventListener('input', function () { if (!ed.dirty) { ed.dirty = true; edStatus('Alterações por gravar'); } });
  ta.addEventListener('keydown', function (e) {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { e.preventDefault(); save(); }
    else if (e.key === 'Tab' && !e.shiftKey) { e.preventDefault(); ta.setRangeText('\t', ta.selectionStart, ta.selectionEnd, 'end'); ta.dispatchEvent(new Event('input')); }
  });
  $('fm-ed-save').addEventListener('click', save);
  $('fm-ed-close').addEventListener('click', edClose);
  $('fm-ed-x').addEventListener('click', edClose);
  edDlg.addEventListener('cancel', function (e) { e.preventDefault(); edClose(); });
  window.addEventListener('beforeunload', function (e) { if (ed.dirty || busy) { e.preventDefault(); e.returnValue = ''; } });

  /* ---------- envios por partes, com retoma ---------- */
  var Q = [], busy = false;
  function hash(s) { var h1 = 0x811c9dc5, h2 = 0x01000193; for (var i = 0; i < s.length; i++) { var c = s.charCodeAt(i); h1 = Math.imul(h1 ^ c, 16777619) >>> 0; h2 = Math.imul(h2 ^ c, 2246822519) >>> 0; } return ('0000000' + h1.toString(16)).slice(-8) + ('0000000' + h2.toString(16)).slice(-8); }
  function upsSummary() {
    var n = Q.length, ok = Q.filter(function (j) { return j.state === 'ok'; }).length, er = Q.filter(function (j) { return j.state === 'err'; }).length;
    $('fm-ups-sum').textContent = ok + ' de ' + n + ' concluído(s)' + (er ? ', ' + er + ' com erro' : '');
  }
  function upRow(job) {
    var d = document.createElement('div'); d.className = 'up';
    d.innerHTML = '<div class="nm2"><span></span><span>em espera</span></div><div class="bar"><i></i></div>';
    d.querySelector('span').textContent = job.rel; $('fm-ups-list').appendChild(d); return d;
  }
  function upSet(job, pct, txt, cls) {
    job.ui.querySelector('i').style.width = pct + '%';
    job.ui.querySelector('.nm2 span:last-child').textContent = txt;
    if (cls) job.ui.className = 'up ' + cls;
  }
  function enqueue(list) {
    if (!list.length) return;
    var p = st.path, site = st.site, names = {};
    st.items.forEach(function (i) { names[i.n] = 1; });
    var clash = list.filter(function (f) { return names[f.rel.split('/')[0]]; }).length;
    var go = clash ? ask('Substituir ficheiros?', clash + ' ficheiro(s) ou pasta(s) com o mesmo nome já existem nesta pasta. Os ficheiros existentes serão substituídos.', null, 'Substituir', true) : Promise.resolve(true);
    go.then(function (ok) {
      if (!ok) return;
      list.forEach(function (f) {
        var job = { f: f.file, rel: f.rel, dir: p, site: site, ow: !!clash, tries: 0, state: 'wait' };
        job.id = 'u' + hash(site + '|' + p + '|' + f.rel + '|' + f.file.size + '|' + f.file.lastModified);
        job.ui = upRow(job); Q.push(job);
      });
      $('fm-ups').hidden = false; upsSummary(); pump();
    });
  }
  function pump() {
    if (busy) return;
    var job = Q.filter(function (j) { return j.state === 'wait'; })[0];
    if (!job) { upsSummary(); if (job === undefined) load(); return; }
    busy = true; job.state = 'run';
    run(job).then(function () { busy = false; upsSummary(); pump(); });
  }
  function run(job) {
    var b = base(job.site);
    function send(off) {
      var fd = new FormData();
      fd.append('id', job.id); fd.append('p', job.dir); fd.append('name', job.rel);
      fd.append('offset', off); fd.append('total', job.f.size);
      if (job.ow) fd.append('overwrite', '1');
      fd.append('chunk', job.f.slice(off, Math.min(off + CH, job.f.size)), 'chunk');
      return fetch(b + '?a=upload', { method: 'POST', credentials: 'same-origin', headers: { 'X-MP-Request': '1' }, body: fd })
        .then(function (r) { if (r.redirected) { location.reload(); throw new Error('A sessão expirou.'); } return r.json().then(function (j) { return { s: r.status, j: j }; }); });
    }
    function loop(off) {
      upSet(job, job.f.size ? Math.floor(off * 100 / job.f.size) : 0, bytes(off) + ' de ' + bytes(job.f.size));
      return send(off).then(function (res) {
        var j = res.j;
        if (j.ok && j.done) { job.state = 'ok'; upSet(job, 100, 'concluído', 'ok'); return; }
        if (j.ok) { job.tries = 0; return loop(j.size); }
        if (j.exists) { var e = new Error(j.error); e.fatal = true; throw e; }
        if (res.s === 409 && typeof j.size === 'number') return loop(j.size);
        throw new Error(j.error || 'Falha no envio.');
      });
    }
    return fetch(b + '?a=upstat&id=' + job.id, { credentials: 'same-origin', headers: { 'X-MP-Request': '1' }, cache: 'no-store' })
      .then(function (r) { return r.json(); }).then(function (j) { return loop(j.size || 0); })
      .catch(function (e) {
        job.tries++;
        if (!e.fatal && job.tries <= 6) {
          upSet(job, 0, 'a retomar (' + job.tries + ')…');
          return new Promise(function (r) { setTimeout(r, 1500 * job.tries); }).then(function () { return run(job); });
        }
        job.state = 'err'; upSet(job, 100, e.message || 'erro', 'err');
      });
  }
  $('fm-ups-close').addEventListener('click', function () {
    if (busy && !window.confirm('Há envios em curso. Esconder o painel de envios? Os envios continuam.')) return;
    if (!busy) { Q = Q.filter(function (j) { return j.state === 'wait' || j.state === 'run'; }); $('fm-ups-list').innerHTML = ''; }
    $('fm-ups').hidden = true;
  });
  function fromInput(input) {
    var list = Array.prototype.map.call(input.files, function (f) { return { file: f, rel: f.webkitRelativePath || f.name }; });
    input.value = ''; enqueue(list);
  }
  $('fm-upfiles').addEventListener('change', function (e) { fromInput(e.target); });
  $('fm-updir').addEventListener('change', function (e) { fromInput(e.target); });

  var drop = $('fm-drop'), depth = 0;
  function walk(en, pre) {
    if (en.isFile) return new Promise(function (res) { en.file(function (f) { res([{ file: f, rel: pre + f.name }]); }, function () { res([]); }); });
    if (!en.isDirectory) return Promise.resolve([]);
    var rd = en.createReader(), all = [];
    return new Promise(function (res) {
      (function next() {
        rd.readEntries(function (list) {
          if (!list.length) {
            Promise.all(all.map(function (c) { return walk(c, pre + en.name + '/'); })).then(function (a) { res([].concat.apply([], a)); });
          } else { all = all.concat(Array.prototype.slice.call(list)); next(); }
        }, function () { res([]); });
      })();
    });
  }
  drop.addEventListener('dragenter', function (e) { if (e.dataTransfer && Array.prototype.indexOf.call(e.dataTransfer.types, 'Files') >= 0) { depth++; drop.classList.add('over'); } });
  drop.addEventListener('dragover', function (e) { e.preventDefault(); });
  drop.addEventListener('dragleave', function () { if (--depth <= 0) { depth = 0; drop.classList.remove('over'); } });
  drop.addEventListener('drop', function (e) {
    e.preventDefault(); depth = 0; drop.classList.remove('over');
    var dt = e.dataTransfer, items = dt.items;
    if (items && items.length && items[0].webkitGetAsEntry) {
      var entries = [];
      for (var i = 0; i < items.length; i++) { var en = items[i].webkitGetAsEntry(); if (en) entries.push(en); }
      Promise.all(entries.map(function (en) { return walk(en, ''); })).then(function (a) { enqueue([].concat.apply([], a)); });
    } else {
      enqueue(Array.prototype.map.call(dt.files, function (f) { return { file: f, rel: f.name }; }));
    }
  });

  load(root.getAttribute('data-dir') || '');
})();
</script>
<?php endif; ?>
</body>
</html>
