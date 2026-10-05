<?php
/**
 * IDDigital Hosting v2.14.1 — gestor de ficheiros (API)
 * Corre num pool PHP-FPM próprio de cada site, como o utilizador do site (mp_<site>),
 * preso à pasta /srv/www/<site> por open_basedir. O acesso é protegido pela sessão
 * do painel (auth_request no nginx) e os pedidos de escrita exigem o cabeçalho
 * X-MP-Request, que um formulário de outro site não consegue enviar.
 */
declare(strict_types=1);

const FM_MAX_EDIT = 2097152;   // 2 MB
const FM_ESSENTIAL = ['public_html', 'logs', 'tmp'];

header('X-Content-Type-Options: nosniff');
header('Cache-Control: no-store');
header("Content-Security-Policy: default-src 'none'; frame-ancestors 'none'; sandbox");

function fm_json(array $d, int $code = 200): void {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($d, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}
function fm_fail(int $code, string $m, array $extra = []): void { fm_json(['ok' => false, 'error' => $m] + $extra, $code); }

$site = (string)($_SERVER['MP_FM_SITE'] ?? '');
if ($site === '_email') {
    // área Email: todas as caixas de correio (corre como vmail); as mensagens não se editam aqui
    $ROOT = realpath('/var/mail/vhosts');
    $TMP = '/var/lib/minipainel-mailfm';
    $NOEDIT = true;
} else {
    if (!preg_match('/^[a-z][a-z0-9-]{0,23}$/', $site)) fm_fail(400, 'Site inválido.');
    $ROOT = realpath('/srv/www/' . $site);
    $TMP = $ROOT === false ? '' : $ROOT . '/tmp';
    $NOEDIT = false;
}
if ($ROOT === false || !is_dir($ROOT)) fm_fail(404, 'A pasta não foi encontrada.');
umask(0027);

/* ---------- caminhos ---------- */
function fm_rel(string $p): string {
    $p = str_replace('\\', '/', $p);
    if (strpos($p, "\0") !== false) fm_fail(400, 'Caminho inválido.');
    $out = [];
    foreach (explode('/', $p) as $seg) {
        if ($seg === '' || $seg === '.') continue;
        if ($seg === '..') fm_fail(400, 'Caminho inválido.');
        if (strlen($seg) > 255) fm_fail(400, 'Nome demasiado longo.');
        $out[] = $seg;
    }
    return implode('/', $out);
}
function fm_join(string $a, string $b): string { return $a === '' ? $b : ($b === '' ? $a : $a . '/' . $b); }
function fm_inside(string $real): bool { global $ROOT; return $real === $ROOT || strpos($real, $ROOT . '/') === 0; }
/* Caminho existente, seguindo ligações simbólicas (para ler e listar) */
function fm_abs(string $rel): string {
    global $ROOT;
    $real = realpath($rel === '' ? $ROOT : $ROOT . '/' . $rel);
    if ($real === false) fm_fail(404, 'Não encontrado: /' . $rel);
    if (!fm_inside($real)) fm_fail(403, 'Fora da pasta do site.');
    return $real;
}
/* Entrada a alterar (não segue a ligação final: apagar uma ligação apaga só a ligação) */
function fm_entry(string $rel, bool $mustExist = true): string {
    global $ROOT;
    if ($rel === '') fm_fail(400, 'Operação não permitida na raiz do site.');
    $parent = realpath(dirname($ROOT . '/' . $rel));
    if ($parent === false || !fm_inside($parent)) fm_fail(403, 'Fora da pasta do site.');
    $abs = $parent . '/' . basename($rel);
    if ($mustExist && !file_exists($abs) && !is_link($abs)) fm_fail(404, 'Não encontrado: /' . $rel);
    return $abs;
}
function fm_name(string $n): string {
    $n = trim($n);
    if ($n === '' || $n === '.' || $n === '..' || strpos($n, '/') !== false || strpos($n, '\\') !== false || strpos($n, "\0") !== false || strlen($n) > 255) {
        fm_fail(400, 'Nome inválido.');
    }
    return $n;
}
function fm_fix(string $abs): void {
    if (is_link($abs)) return;
    @chmod($abs, is_dir($abs) ? 02750 : 0640);
}
function fm_mkdirs(string $abs): void {
    if (is_dir($abs)) return;
    fm_mkdirs(dirname($abs));
    if (!@mkdir($abs) && !is_dir($abs)) fm_fail(500, 'Não foi possível criar a pasta ' . basename($abs) . '.');
    fm_fix($abs);
}
function fm_rrm(string $p): bool {
    if (is_link($p) || !is_dir($p)) return @unlink($p);
    $ok = true;
    foreach ((array)@scandir($p) as $e) {
        if ($e === '.' || $e === '..' || $e === false) continue;
        $ok = fm_rrm($p . '/' . $e) && $ok;
    }
    return @rmdir($p) && $ok;
}
function fm_essential(string $rel): bool { return strpos($rel, '/') === false && in_array($rel, FM_ESSENTIAL, true); }

/* ---------- entrada ---------- */
$a = (string)($_GET['a'] ?? '');
$method = (string)($_SERVER['REQUEST_METHOD'] ?? 'GET');
$in = [];
if ($method === 'POST') {
    if ((string)($_SERVER['HTTP_X_MP_REQUEST'] ?? '') !== '1') fm_fail(403, 'Pedido recusado.');
    $in = $_POST;
    if (stripos((string)($_SERVER['CONTENT_TYPE'] ?? ''), 'application/json') === 0) {
        $j = json_decode((string)file_get_contents('php://input'), true);
        $in = is_array($j) ? $j : [];
    }
}
function in_s(array $in, string $k): string { $v = $in[$k] ?? ''; return is_string($v) || is_int($v) ? (string)$v : ''; }
function in_list(array $in, string $k): array { $v = $in[$k] ?? []; return is_array($v) ? array_values(array_filter($v, 'is_string')) : []; }
function q(string $k): string { $v = $_GET[$k] ?? ''; return is_string($v) ? $v : ''; }

$readOnly = ['list', 'get', 'dl', 'upstat', 'logs', 'tail'];
if ($method !== 'POST' && !in_array($a, $readOnly, true)) fm_fail(405, 'Método não permitido.');

switch ($a) {

case 'list':
    $rel = fm_rel(q('p'));
    $dir = fm_abs($rel);
    if (!is_dir($dir)) fm_fail(400, 'Não é uma pasta.');
    $dh = @opendir($dir);
    if ($dh === false) fm_fail(403, 'Sem permissão para ler esta pasta.');
    $items = [];
    while (($e = readdir($dh)) !== false) {
        if ($e === '.' || $e === '..') continue;
        $f = $dir . '/' . $e;
        $st = @lstat($f);
        if ($st === false) continue;
        $link = is_link($f);
        $isDir = is_dir($f);
        $items[] = [
            'n' => $e, 'd' => $isDir, 'l' => $link,
            's' => $isDir ? null : ($link ? @filesize($f) : $st['size']),
            'm' => $st['mtime'], 'p' => sprintf('%04o', $st['mode'] & 07777),
        ];
    }
    closedir($dh);
    usort($items, function ($x, $y) { return $x['d'] === $y['d'] ? strnatcasecmp($x['n'], $y['n']) : ($x['d'] ? -1 : 1); });
    $free = @disk_free_space($dir);
    fm_json(['ok' => true, 'path' => $rel, 'items' => $items, 'free' => $free === false ? null : $free]);

case 'get':
    if ($NOEDIT) fm_fail(403, 'Na área Email as mensagens não se editam aqui (podes descarregá-las).');
    $f = fm_abs(fm_rel(q('p')));
    if (!is_file($f)) fm_fail(400, 'Não é um ficheiro.');
    if ((int)filesize($f) > FM_MAX_EDIT) fm_fail(413, 'O ficheiro tem mais de 2 MB; descarrega-o para editar.');
    $c = @file_get_contents($f);
    if ($c === false) fm_fail(403, 'Sem permissão para ler o ficheiro.');
    if (strpos($c, "\0") !== false || !preg_match('//u', $c)) fm_fail(415, 'É um ficheiro binário ou não está em UTF-8; não pode ser editado aqui.');
    fm_json(['ok' => true, 'content' => $c, 'm' => filemtime($f)]);

case 'dl':
    $f = fm_abs(fm_rel(q('p')));
    if (!is_file($f) || !is_readable($f)) fm_fail(404, 'Ficheiro não encontrado.');
    @set_time_limit(0);
    while (ob_get_level() > 0) ob_end_clean();
    header('Content-Type: application/octet-stream');
    header('Content-Length: ' . (string)filesize($f));
    header("Content-Disposition: attachment; filename*=UTF-8''" . rawurlencode(basename($f)));
    readfile($f);
    exit;

case 'logs':
    // lista os logs da pasta logs do site (atuais e rodados)
    if ($NOEDIT) fm_fail(400, 'Pedido inválido.');
    $out = [];
    foreach ((array)glob($ROOT . '/logs/*') as $lf) {
        $b = basename((string)$lf);
        if (!is_file((string)$lf) || is_link((string)$lf) || !preg_match('/^[A-Za-z0-9._-]+\.log([.-][0-9A-Za-z.-]+)?$/', $b)) continue;
        $out[] = ['n' => $b, 's' => (int)filesize((string)$lf), 'm' => (int)filemtime((string)$lf)];
    }
    usort($out, function ($a, $b) { return $b['m'] <=> $a['m']; });
    fm_json(['ok' => true, 'items' => $out]);

case 'tail':
    // últimas linhas de um log da pasta logs (sem seguir ligações simbólicas)
    if ($NOEDIT) fm_fail(400, 'Pedido inválido.');
    $b = basename(q('p'));
    if (!preg_match('/^[A-Za-z0-9._-]+\.log$/', $b)) fm_fail(400, 'Ficheiro inválido.');
    $lf = $ROOT . '/logs/' . $b;
    if (!is_file($lf) || is_link($lf)) fm_json(['ok' => true, 'lines' => [], 'size' => 0]);
    $max = max(10, min(5000, (int)q('n') ?: 500)); $grep = (string)q('q');
    $fh = @fopen($lf, 'r'); if (!$fh) fm_fail(403, 'Sem permissão para ler o log.');
    $size = (int)filesize($lf); $chunk = 65536; $pos = $size; $buf = ''; $lines = [];
    while ($pos > 0 && count($lines) < $max && $size - $pos < 33554432) {
        $rd = min($chunk, $pos); $pos -= $rd; fseek($fh, $pos); $buf = (string)fread($fh, $rd) . $buf;
        $parts = explode("\n", $buf); $buf = $pos > 0 ? (string)array_shift($parts) : '';
        $sel = [];
        foreach ($parts as $ln) { if ($ln === '') continue; if ($grep !== '' && stripos($ln, $grep) === false) continue; $sel[] = mb_substr($ln, 0, 2000); }
        $lines = array_merge($sel, $lines);
    }
    if ($buf !== '' && ($grep === '' || stripos($buf, $grep) !== false)) array_unshift($lines, $buf);
    fclose($fh);
    fm_json(['ok' => true, 'lines' => array_slice($lines, -$max), 'size' => $size]);

case 'upstat':
    $id = q('id');
    if (!preg_match('/^[A-Za-z0-9_-]{8,64}$/', $id)) fm_fail(400, 'Identificador inválido.');
    $part = $TMP . '/.mp-up-' . $id . '.part';
    fm_json(['ok' => true, 'size' => is_file($part) ? filesize($part) : 0]);

case 'mkdir':
case 'newfile':
    $dir = fm_abs(fm_rel(in_s($in, 'p')));
    if (!is_dir($dir)) fm_fail(400, 'A pasta de destino não existe.');
    $t = $dir . '/' . fm_name(in_s($in, 'name'));
    if (file_exists($t) || is_link($t)) fm_fail(409, 'Já existe um ficheiro ou pasta com esse nome.');
    $ok = $a === 'mkdir' ? @mkdir($t) : (@file_put_contents($t, '') !== false);
    if (!$ok) fm_fail(500, 'Não foi possível criar.');
    fm_fix($t);
    fm_json(['ok' => true]);

case 'rename':
    $p = fm_rel(in_s($in, 'p'));
    $from = fm_name(in_s($in, 'from'));
    $to = fm_name(in_s($in, 'to'));
    if (fm_essential(fm_join($p, $from))) fm_fail(403, 'Esta pasta é essencial para o site e não pode mudar de nome.');
    $src = fm_entry(fm_join($p, $from));
    $dst = fm_entry(fm_join($p, $to), false);
    if (file_exists($dst) || is_link($dst)) fm_fail(409, 'Já existe um ficheiro ou pasta com esse nome.');
    if (!@rename($src, $dst)) fm_fail(500, 'Não foi possível mudar o nome.');
    fm_json(['ok' => true]);

case 'move':
    $p = fm_rel(in_s($in, 'p'));
    $destRel = fm_rel(in_s($in, 'to'));
    $dest = fm_abs($destRel);
    if (!is_dir($dest)) fm_fail(400, 'O destino não é uma pasta.');
    $errors = [];
    foreach (in_list($in, 'items') as $it) {
        $rel = fm_join($p, fm_name($it));
        if (fm_essential($rel)) { $errors[] = $it . ': pasta essencial'; continue; }
        $src = fm_entry($rel);
        $real = realpath($src);
        if ($real !== false && is_dir($src) && !is_link($src) && ($dest === $real || strpos($dest . '/', $real . '/') === 0)) { $errors[] = $it . ': não pode ir para dentro de si própria'; continue; }
        $t = $dest . '/' . basename($src);
        if (file_exists($t) || is_link($t)) { $errors[] = $it . ': já existe no destino'; continue; }
        if (!@rename($src, $t)) $errors[] = $it . ': falhou';
    }
    if ($errors) fm_fail(409, "Alguns itens não foram movidos:\n" . implode("\n", $errors));
    fm_json(['ok' => true]);

case 'delete':
    $p = fm_rel(in_s($in, 'p'));
    $errors = [];
    foreach (in_list($in, 'items') as $it) {
        $rel = fm_join($p, fm_name($it));
        if (fm_essential($rel)) { $errors[] = $it . ': pasta essencial do site'; continue; }
        if (!fm_rrm(fm_entry($rel))) $errors[] = $it;
    }
    if ($errors) fm_fail(409, "Não foi possível apagar:\n" . implode("\n", $errors));
    fm_json(['ok' => true]);

case 'save':
    if ($NOEDIT) fm_fail(403, 'Na área Email as mensagens não se editam aqui.');
    $rel = fm_rel(in_s($in, 'p'));
    $f = fm_entry($rel, false);
    $content = in_s($in, 'content');
    if (strlen($content) > FM_MAX_EDIT) fm_fail(413, 'O conteúdo tem mais de 2 MB.');
    if (is_dir($f)) fm_fail(400, 'É uma pasta.');
    $new = !file_exists($f);
    if (@file_put_contents($f, $content, LOCK_EX) === false) fm_fail(500, 'Não foi possível gravar o ficheiro.');
    if ($new) fm_fix($f);
    clearstatcache(true, $f);
    fm_json(['ok' => true, 'm' => filemtime($f)]);

case 'chmod':
    $p = fm_rel(in_s($in, 'p'));
    $mode = in_s($in, 'mode');
    if (!preg_match('/^[0-7]{3,4}$/', $mode)) fm_fail(400, 'Permissões inválidas (ex.: 640 ou 2750).');
    $errors = [];
    foreach (in_list($in, 'items') as $it) {
        $f = fm_entry(fm_join($p, fm_name($it)));
        if (is_link($f)) continue;
        if (!@chmod($f, octdec($mode))) $errors[] = $it;
    }
    if ($errors) fm_fail(409, "Não foi possível alterar:\n" . implode("\n", $errors));
    fm_json(['ok' => true]);

case 'extract':
    @set_time_limit(0);
    $rel = fm_rel(in_s($in, 'p'));
    $arch = fm_abs($rel);
    if (!is_file($arch)) fm_fail(400, 'Não é um ficheiro.');
    $dest = dirname($arch);
    $sub = trim(in_s($in, 'into'));
    if ($sub !== '') { $dest .= '/' . fm_name($sub); fm_mkdirs($dest); }
    $lower = strtolower($arch);
    $count = 0; $skipped = 0;
    $safeTarget = function (string $name) use ($dest, &$skipped): ?string {
        $name = str_replace('\\', '/', $name);
        $parts = [];
        foreach (explode('/', $name) as $seg) {
            if ($seg === '' || $seg === '.') continue;
            if ($seg === '..' || strpos($seg, "\0") !== false) { $skipped++; return null; }
            $parts[] = $seg;
        }
        return $parts ? $dest . '/' . implode('/', $parts) : null;
    };
    if (substr($lower, -4) === '.zip') {
        if (!class_exists('ZipArchive')) fm_fail(500, 'A extensão zip do PHP não está disponível.');
        $z = new ZipArchive();
        if ($z->open($arch) !== true) fm_fail(400, 'Não foi possível abrir o ZIP.');
        for ($i = 0; $i < $z->numFiles; $i++) {
            $name = (string)$z->getNameIndex($i);
            $t = $safeTarget($name);
            if ($t === null) continue;
            if (substr($name, -1) === '/') { fm_mkdirs($t); continue; }
            fm_mkdirs(dirname($t));
            if (is_link($t)) @unlink($t);
            $src = $z->getStream($name);
            $dst = @fopen($t, 'wb');
            if ($src === false || $dst === false) { $skipped++; continue; }
            stream_copy_to_stream($src, $dst);
            fclose($src); fclose($dst);
            fm_fix($t);
            $count++;
        }
        $z->close();
    } elseif (preg_match('/\.(tar\.gz|tgz|tar\.bz2|tar)$/', $lower)) {
        if (!class_exists('PharData')) fm_fail(500, 'A extensão phar do PHP não está disponível.');
        try {
            $ph = new PharData($arch);
            $prefix = 'phar://' . $arch . '/';
            foreach (new RecursiveIteratorIterator($ph, RecursiveIteratorIterator::SELF_FIRST) as $entry) {
                $path = (string)$entry->getPathname();
                if (strpos($path, $prefix) !== 0) { $skipped++; continue; }
                $t = $safeTarget(substr($path, strlen($prefix)));
                if ($t === null) continue;
                if ($entry->isDir()) { fm_mkdirs($t); continue; }
                fm_mkdirs(dirname($t));
                if (is_link($t)) @unlink($t);
                if (!@copy($path, $t)) { $skipped++; continue; }
                fm_fix($t);
                $count++;
            }
        } catch (Throwable $e) {
            fm_fail(400, 'Não foi possível ler o arquivo: ' . $e->getMessage());
        }
    } else {
        fm_fail(400, 'Formato não suportado. Usa .zip, .tar, .tar.gz, .tgz ou .tar.bz2.');
    }
    fm_json(['ok' => true, 'count' => $count, 'skipped' => $skipped]);

case 'zip':
    @set_time_limit(0);
    if (!class_exists('ZipArchive')) fm_fail(500, 'A extensão zip do PHP não está disponível.');
    $p = fm_rel(in_s($in, 'p'));
    $dir = fm_abs($p);
    $name = fm_name(in_s($in, 'name'));
    if (strtolower(substr($name, -4)) !== '.zip') $name .= '.zip';
    $target = $dir . '/' . $name;
    if (file_exists($target)) fm_fail(409, 'Já existe um ficheiro com esse nome.');
    $z = new ZipArchive();
    if ($z->open($target, ZipArchive::CREATE) !== true) fm_fail(500, 'Não foi possível criar o ZIP.');
    $added = 0;
    $addPath = function (string $abs, string $local) use (&$addPath, $z, $target, &$added) {
        if ($abs === $target) return;
        if (is_link($abs)) return;
        if (is_dir($abs)) {
            $z->addEmptyDir($local);
            foreach ((array)@scandir($abs) as $e) {
                if ($e === '.' || $e === '..' || $e === false) continue;
                $addPath($abs . '/' . $e, $local . '/' . $e);
            }
        } elseif (is_readable($abs)) {
            $z->addFile($abs, $local);
            $added++;
        }
    };
    foreach (in_list($in, 'items') as $it) {
        $it = fm_name($it);
        $addPath(fm_entry(fm_join($p, $it)), $it);
    }
    if (!$z->close()) fm_fail(500, 'Falha ao gravar o ZIP.');
    fm_fix($target);
    fm_json(['ok' => true, 'name' => $name, 'count' => $added]);

case 'upload':
    @set_time_limit(0);
    $id = in_s($in, 'id');
    if (!preg_match('/^[A-Za-z0-9_-]{8,64}$/', $id)) fm_fail(400, 'Identificador inválido.');
    $offset = (int)in_s($in, 'offset');
    $total = (int)in_s($in, 'total');
    if ($offset < 0 || $total < 0) fm_fail(400, 'Valores inválidos.');
    $dir = fm_abs(fm_rel(in_s($in, 'p')));
    if (!is_dir($dir)) fm_fail(400, 'A pasta de destino não existe.');
    $relName = fm_rel(in_s($in, 'name'));
    if ($relName === '') fm_fail(400, 'Nome inválido.');
    foreach (explode('/', $relName) as $seg) fm_name($seg);
    $part = $TMP . '/.mp-up-' . $id . '.part';
    if (!is_dir($TMP)) fm_fail(500, 'A pasta temporária não existe.');
    // limpa envios abandonados há mais de um dia
    if (mt_rand(1, 20) === 1) foreach ((array)glob($TMP . '/.mp-up-*.part') as $old) { if (is_string($old) && filemtime($old) < time() - 86400) @unlink($old); }
    clearstatcache(true, $part);
    $have = is_file($part) ? (int)filesize($part) : 0;
    if ($offset !== $have) fm_fail(409, 'Fora de sequência.', ['size' => $have]);
    $chunk = $_FILES['chunk'] ?? null;
    if ($total > 0) {
        if (!is_array($chunk) || (int)($chunk['error'] ?? 1) !== UPLOAD_ERR_OK) fm_fail(400, 'A parte do ficheiro não chegou ao servidor.');
        $src = @fopen((string)$chunk['tmp_name'], 'rb');
        $dst = @fopen($part, 'ab');
        if ($src === false || $dst === false) fm_fail(500, 'Não foi possível gravar a parte do ficheiro.');
        stream_copy_to_stream($src, $dst);
        fclose($src); fclose($dst);
        clearstatcache(true, $part);
        $have = (int)filesize($part);
    } elseif (!is_file($part)) {
        @touch($part);
    }
    if ($have > $total) { @unlink($part); fm_fail(409, 'O tamanho recebido não confere; recomeça o envio.', ['size' => 0]); }
    if ($have < $total) fm_json(['ok' => true, 'size' => $have, 'done' => false]);
    $target = $dir . '/' . $relName;
    fm_mkdirs(dirname($target));
    if (file_exists($target) || is_link($target)) {
        if (in_s($in, 'overwrite') !== '1' || is_dir($target)) { @unlink($part); fm_fail(409, 'Já existe: ' . $relName, ['exists' => true]); }
        @unlink($target);
    }
    if (!@rename($part, $target)) fm_fail(500, 'Não foi possível concluir o envio.');
    fm_fix($target);
    fm_json(['ok' => true, 'size' => $have, 'done' => true]);

default:
    fm_fail(400, 'Ação desconhecida.');
}
