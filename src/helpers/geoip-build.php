<?php
// IDDigital Hosting — constrói os índices de geolocalização a partir do CSV da DB-IP (CC BY 4.0)
// uso: php geoip-build.php <csv.gz> <pasta>
[$src, $dir] = [$argv[1] ?? '', $argv[2] ?? ''];
$in = gzopen($src, 'r'); if (!$in) { fwrite(STDERR, "CSV ilegível\n"); exit(1); }
@mkdir($dir . '/cc', 0750, true);
$v4 = fopen($dir . '/v4.bin.tmp', 'w'); $v6 = fopen($dir . '/v6.bin.tmp', 'w');
$cc4 = []; $cc6 = []; $n = 0;
while (($ln = gzgets($in)) !== false) {
    $p = explode(',', trim($ln)); if (count($p) !== 3) continue;
    [$a, $b, $c] = $p; if (!preg_match('/^[A-Z]{2}$/', $c) || $c === 'ZZ') continue;
    if (strpos($a, ':') === false) {
        $x = ip2long($a); $y = ip2long($b); if ($x === false || $y === false) continue;
        fwrite($v4, pack('NN', $x, $y) . $c); $cc4[$c][] = "$a-$b";
    } else {
        $x = @inet_pton($a); $y = @inet_pton($b); if ($x === false || $y === false) continue;
        fwrite($v6, $x . $y . $c); $cc6[$c][] = "$a-$b";
    }
    $n++;
}
gzclose($in); fclose($v4); fclose($v6);
if ($n < 100000) { fwrite(STDERR, "CSV incompleto ($n linhas)\n"); exit(1); }
foreach (glob($dir . '/cc/*') as $f) @unlink($f);
foreach ($cc4 as $c => $l) file_put_contents("$dir/cc/$c.v4", implode("\n", $l) . "\n");
foreach ($cc6 as $c => $l) file_put_contents("$dir/cc/$c.v6", implode("\n", $l) . "\n");
rename($dir . '/v4.bin.tmp', $dir . '/v4.bin'); rename($dir . '/v6.bin.tmp', $dir . '/v6.bin');
echo "$n gamas, " . count($cc4) . " países\n";
