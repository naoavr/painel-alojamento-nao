site_placeholder(){ # página "Brevemente" dos sites novos (um só ficheiro, sem recursos externos)
  cat <<'MPPLACEHOLDER'
<!doctype html>
<html lang="pt-PT">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>Brevemente</title>
<style>
:root{--bg1:#0f2a44;--bg2:#174f6e;--bg3:#1f8a8a;--ink:#ffffff;--mu:rgba(255,255,255,.78);--card:rgba(255,255,255,.08);--line:rgba(255,255,255,.18)}
@media (prefers-color-scheme:light){:root{--bg1:#e9f1f8;--bg2:#d6e7f3;--bg3:#cfeeea;--ink:#0f2236;--mu:#41566b;--card:rgba(255,255,255,.65);--line:rgba(15,34,54,.12)}}
*{box-sizing:border-box}
html,body{height:100%;margin:0}
body{min-height:100vh;display:flex;flex-direction:column;font:16px/1.6 system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:var(--ink);
  background:linear-gradient(135deg,var(--bg1),var(--bg2) 55%,var(--bg3));background-size:200% 200%;animation:bg 18s ease-in-out infinite;overflow-x:hidden}
@keyframes bg{0%,100%{background-position:0% 50%}50%{background-position:100% 50%}}
.orb{position:fixed;border-radius:50%;filter:blur(60px);opacity:.35;pointer-events:none}
.orb.a{width:46vw;height:46vw;left:-12vw;top:-14vw;background:#3fb6c9;animation:fl 22s ease-in-out infinite}
.orb.b{width:38vw;height:38vw;right:-10vw;bottom:-14vw;background:#5a7bff;animation:fl 26s ease-in-out infinite reverse}
@keyframes fl{0%,100%{transform:translate(0,0)}50%{transform:translate(4vw,3vw)}}
@media (prefers-reduced-motion:reduce){body,.orb{animation:none}}
header{position:relative;padding:28px 7vw 0;display:flex;align-items:center}
header a{color:var(--ink);display:inline-flex}
.logo{height:clamp(34px,3.4vw,46px);width:auto;display:block}
main{flex:1;display:flex;align-items:center;width:100%;padding:6vh 7vw 8vh;position:relative}
.wrap{width:100%;display:grid;grid-template-columns:minmax(0,1.25fr) minmax(0,1fr);gap:6vw;align-items:center}
.tag{display:inline-flex;align-items:center;gap:10px;padding:8px 16px;border:1px solid var(--line);border-radius:999px;background:var(--card);backdrop-filter:blur(8px);font-size:14px;font-weight:600;letter-spacing:.04em;text-transform:uppercase}
.dot{width:9px;height:9px;border-radius:50%;background:#43d39e;box-shadow:0 0 0 0 rgba(67,211,158,.6);animation:pu 2s infinite}
@keyframes pu{0%{box-shadow:0 0 0 0 rgba(67,211,158,.6)}70%{box-shadow:0 0 0 12px rgba(67,211,158,0)}100%{box-shadow:0 0 0 0 rgba(67,211,158,0)}}
h1{font-size:clamp(34px,6.4vw,96px);line-height:1.04;margin:28px 0 18px;font-weight:800;letter-spacing:-.03em;white-space:nowrap}
.lead{font-size:clamp(18px,1.6vw,22px);color:var(--mu);max-width:36em;margin:0}
.en{margin-top:10px;font-size:15px;color:var(--mu);opacity:.85}
.panel{border:1px solid var(--line);border-radius:28px;background:var(--card);backdrop-filter:blur(10px);padding:clamp(24px,3vw,40px)}
.panel h2{font-size:15px;text-transform:uppercase;letter-spacing:.08em;margin:0 0 18px;color:var(--mu);font-weight:700}
.step{display:flex;gap:16px;align-items:flex-start;padding:14px 0;border-top:1px solid var(--line)}
.step:first-of-type{border-top:0;padding-top:0}
.ic{flex:none;width:44px;height:44px;border-radius:14px;display:grid;place-items:center;background:rgba(255,255,255,.12);border:1px solid var(--line)}
.ic svg{width:22px;height:22px}
.step b{display:block;font-size:17px}
.step span{color:var(--mu);font-size:15px}
footer{position:relative;padding:22px 7vw;display:flex;justify-content:space-between;gap:16px;flex-wrap:wrap;font-size:14px;color:var(--mu);border-top:1px solid var(--line)}
@media (max-width:900px){.wrap{grid-template-columns:1fr}main{padding:5vh 7vw 6vh}}
</style>
</head>
<body>
<div class="orb a"></div><div class="orb b"></div>
<header><a href="https://iddigital.pt" rel="noopener" aria-label="IDDigital"><svg class="logo" viewBox="0 0 62.97 18.26" role="img" aria-label="IDDigital" xmlns="http://www.w3.org/2000/svg"><path fill="currentColor" d="M 10.696104,17.232981 C 9.5129773,16.842176 8.7260574,16.372185 7.9458244,15.590365 c -1.114,-1.116262 -1.7157692,-2.493883 -1.784426,-4.085056 -0.014374,-0.333159 -0.00865,-0.457078 0.029917,-0.647164 0.099813,-0.491997 0.3189197,-0.9047228 0.6668116,-1.2560559 0.8274806,-0.8356635 2.1314767,-1.0014038 3.189827,-0.405435 0.261545,0.1472777 0.723354,0.5928945 0.865202,0.8348679 0.214006,0.365059 0.316112,0.722462 0.350283,1.226095 0.0346,0.509923 0.209212,0.888772 0.54975,1.192761 0.343775,0.306876 0.717013,0.444297 1.196753,0.440625 0.525886,-0.004 0.905248,-0.154464 1.248715,-0.495181 0.235108,-0.233227 0.351055,-0.432298 0.431021,-0.740031 0.05275,-0.202983 0.05767,-0.273977 0.0419,-0.604108 C 14.662552,9.6065015 14.075119,8.3362136 12.999265,7.3056355 12.048684,6.3950566 10.862731,5.8387523 9.4907979,5.6598913 9.0218609,5.5987579 8.1134294,5.6186003 7.6756472,5.6995508 6.3679108,5.9413587 5.3155828,6.4713126 4.423572,7.3373012 3.910517,7.8353884 3.5632817,8.3130464 3.2715718,8.9219956 2.8556734,9.7901897 2.6909166,10.742689 2.7685575,11.830049 c 0.055923,0.783182 0.1672461,1.327816 0.436759,2.136766 0.1797827,0.539622 0.1806174,0.605202 0.00988,0.77594 -0.094738,0.09474 -0.119626,0.105283 -0.248473,0.105283 -0.1660019,0 -0.2799034,-0.05074 -0.3567817,-0.158919 C 2.5458511,14.598936 2.3598961,14.029801 2.2414377,13.561284 1.9117912,12.2575 1.8815863,10.789106 2.1618329,9.6914849 2.5560106,8.147645 3.6460195,6.7437251 5.1475424,5.8459267 7.3224606,4.545487 10.115883,4.5274669 12.319362,5.7996657 c 1.715935,0.9907074 2.873217,2.6135551 3.201846,4.4899243 0.07645,0.436502 0.110227,0.99086 0.07811,1.282039 -0.09176,0.832016 -0.604065,1.554468 -1.370112,1.932141 -0.425591,0.209822 -0.613626,0.24943 -1.177703,0.248064 -0.448773,-0.0011 -0.503433,-0.007 -0.732963,-0.07746 -0.87301,-0.268526 -1.522411,-0.925309 -1.734383,-1.754115 -0.02862,-0.111896 -0.06518,-0.356227 -0.08124,-0.542947 -0.03397,-0.394862 -0.102412,-0.627427 -0.25685,-0.872738 C 10.033828,10.167463 9.6093692,9.8704218 9.1869714,9.7634095 8.9528412,9.7040972 8.5620269,9.7097502 8.3021585,9.7762077 7.7275959,9.9231553 7.3086886,10.298932 7.111982,10.843844 c -0.074054,0.205143 -0.079853,0.249702 -0.077714,0.597194 0.00823,1.338483 0.5321468,2.601535 1.4809618,3.57036 0.7632773,0.779376 1.5081182,1.232518 2.5716382,1.564519 0.385877,0.120458 0.468886,0.189169 0.489653,0.405307 0.01075,0.111391 0.0027,0.152793 -0.03858,0.199197 -0.06269,0.07051 -0.307281,0.189422 -0.384621,0.187006 -0.03048,-9.44e-4 -0.236233,-0.06145 -0.457226,-0.134457 z M 6.6904661,17.164437 C 6.6024841,17.126114 6.1242485,16.631374 5.8040522,16.247429 5.3889771,15.749717 4.8134382,14.798822 4.5796876,14.224554 4.2080316,13.311486 4.0390981,12.44863 4.0344449,11.439633 4.0315488,10.812052 4.0523334,10.622866 4.1714275,10.192654 4.4032301,9.3552972 4.7979022,8.7065962 5.4566054,8.0802783 6.6288369,6.9656805 8.3477125,6.53442 9.9677565,6.9484445 11.395991,7.3134498 12.624593,8.385578 13.130529,9.7084047 c 0.179752,0.4699833 0.277045,0.9492623 0.284758,1.4027433 0.0039,0.2333 -0.0034,0.280082 -0.05759,0.367839 -0.07922,0.128173 -0.185,0.182331 -0.356132,0.182331 -0.271196,0 -0.421017,-0.180507 -0.42109,-0.50734 C 12.580366,10.630453 12.386096,9.9467474 12.106308,9.4850986 11.519961,8.5176305 10.503356,7.8549032 9.3382846,7.6806177 8.9765395,7.6265032 8.2377737,7.6433484 7.9250422,7.712841 6.3064884,8.0725247 5.1663437,9.216776 4.9019127,10.74686 c -0.048713,0.281867 -0.040483,1.037965 0.016134,1.482521 0.1392626,1.093469 0.435231,1.866856 1.1081841,2.895762 0.2908723,0.444728 0.4825181,0.683363 0.8959562,1.115635 0.2592815,0.271092 0.3388777,0.372163 0.3531957,0.448482 0.04265,0.227351 -0.069562,0.416401 -0.2855706,0.48112 -0.138344,0.04144 -0.193019,0.04037 -0.299346,-0.0059 z m 5.5207159,-1.54205 C 11.244805,15.510073 10.366448,15.094396 9.6752993,14.422292 8.8680425,13.637276 8.3961892,12.623707 8.3226635,11.516734 c -0.014569,-0.219391 -0.00898,-0.29249 0.029947,-0.394527 0.085794,-0.224661 0.3138299,-0.316951 0.5552824,-0.224741 0.1893172,0.0723 0.2336623,0.167004 0.2626962,0.561026 0.047867,0.649573 0.2164175,1.171521 0.5465019,1.692305 0.478925,0.755612 1.285532,1.346508 2.129856,1.56027 0.515341,0.130473 0.954321,0.158609 1.522371,0.09758 0.25322,-0.02721 0.502392,-0.04158 0.553715,-0.03196 0.0597,0.01126 0.129162,0.05719 0.192819,0.127645 0.08538,0.09451 0.0995,0.129217 0.0995,0.244514 0,0.157022 -0.07723,0.291864 -0.21238,0.370795 -0.171403,0.100097 -1.271672,0.163198 -1.791791,0.102753 z M 1.5515958,7.1526948 C 1.4873796,7.1293278 1.3569964,7.0003509 1.3135813,6.9172481 1.2251437,6.7479642 1.2653004,6.6170208 1.5014118,6.304768 2.2840541,5.2697396 3.2799235,4.4288405 4.4123052,3.8468473 5.3878281,3.345472 6.3437639,3.0512582 7.537093,2.8851119 c 0.4932469,-0.068671 1.9175775,-0.068671 2.4108249,0 2.4273701,0.3379607 4.3925631,1.4211281 5.8350501,3.2161431 0.273249,0.3400272 0.399842,0.5400029 0.399842,0.6316181 0,0.2252296 -0.195182,0.4254658 -0.414722,0.4254658 -0.07467,0 -0.158537,-0.019956 -0.201131,-0.047867 C 15.526779,7.0841417 15.377686,6.9100193 15.235648,6.7235286 14.506048,5.7655897 13.583182,5.007309 12.512436,4.485975 11.291939,3.8917299 10.097979,3.6209526 8.7009401,3.6215672 7.275676,3.6221957 6.0752471,3.8976143 4.8738546,4.4996332 3.7786794,5.0484254 2.900244,5.7808957 2.1395936,6.779554 2.0080624,6.952241 1.8662182,7.1112306 1.8243846,7.132865 1.7480846,7.172322 1.6292648,7.18096 1.5515958,7.1526948 Z M 3.8100123,2.7920664 C 3.497075,2.6920703 3.4166986,2.3074566 3.6618987,2.0833121 3.8117352,1.9463439 4.7695509,1.5215205 5.4243361,1.3016113 6.1572227,1.0554732 6.9907558,0.87692327 7.7864887,0.79561623 8.1981408,0.75355388 9.2857142,0.75413562 9.7123764,0.79666083 10.709221,0.89598665 11.56665,1.0988344 12.497294,1.4555195 12.959321,1.6326 13.75672,1.9956248 13.830686,2.0625642 13.908374,2.1328789 13.975124,2.3346744 13.95533,2.4394218 13.925446,2.5975653 13.842688,2.700374 13.702032,2.7540914 13.537356,2.8169826 13.504967,2.807915 12.926808,2.5369619 11.598059,1.9142622 10.445355,1.6422506 8.9975808,1.6097578 7.2861158,1.5713503 5.8249633,1.8966278 4.3478231,2.6448848 4.0272707,2.8072624 3.9358377,2.8322874 3.8100123,2.7920828 Z"/><g font-family="Arial,'Liberation Sans',Helvetica,sans-serif" font-weight="700"><text x="18.0823" y="12.868" font-size="11.6841" fill="#16a596">id</text><text x="28.9553" y="12.7322" font-size="11.4367" fill="currentColor">digital</text><text x="60.362" y="15.427" font-size="2.88254" font-weight="400" fill="currentColor" text-anchor="end">hosting</text></g></svg></a></header>
<main>
  <div class="wrap">
    <section>
      <span class="tag"><span class="dot"></span>Brevemente</span>
      <h1 id="d">o seu site</h1>
      <p class="lead">Estamos a preparar um novo site. Volte em breve para conhecer as novidades.</p>
      <p class="en">Coming soon — this website is under construction.</p>
    </section>
    <aside class="panel" aria-label="Estado">
      <h2>Em preparação</h2>
      <div class="step"><div class="ic"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2 4 6v6c0 5 3.5 8.5 8 10 4.5-1.5 8-5 8-10V6z"/><path d="m9 12 2 2 4-4"/></svg></div><div><b>Domínio ativo</b><span>O endereço já está ligado a este servidor.</span></div></div>
      <div class="step"><div class="ic"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 20h4L18.5 9.5a2.1 2.1 0 0 0-3-3L5 17v3z"/><path d="m14 7 3 3"/></svg></div><div><b>Conteúdos em construção</b><span>Textos, imagens e páginas a caminho.</span></div></div>
      <div class="step"><div class="ic"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg></div><div><b>Disponível em breve</b><span>Obrigado pela visita e pela paciência.</span></div></div>
    </aside>
  </div>
</main>
<footer><span id="f">&copy; <span id="y"></span></span><span id="h"></span></footer>
<script>
(function(){var h=(location.hostname||"").replace(/^www\./,"");var ip=/^[0-9.]+$|:/.test(h);
document.getElementById("d").textContent=h&&!ip?h:"o seu site";document.getElementById("y").textContent=new Date().getFullYear();
document.getElementById("h").textContent=h&&!ip?h:"";if(h&&!ip)document.title=h+" — Brevemente";
var t=document.getElementById("d");function fit(){t.style.fontSize="";var w=t.parentNode.clientWidth,s=parseFloat(getComputedStyle(t).fontSize);while(t.scrollWidth>w&&s>18){s-=2;t.style.fontSize=s+"px";}}
fit();addEventListener("resize",fit);})();
</script>
</body>
</html>
MPPLACEHOLDER
}
site_placeholder_old(){ # nome versão -> a página que as versões anteriores criavam (para a reconhecer sem tocar em conteúdo do utilizador)
  local n=$1 v=$2 d="$WWW_ROOT/$1"
  cat <<EOF
<!doctype html>
<html lang="pt-PT"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>$n</title>
<style>html,body{height:100%;margin:0}body{display:flex;align-items:center;justify-content:center;font:16px/1.5 system-ui,sans-serif;background:#eaeef2;color:#16222e}div{text-align:center;padding:24px}h1{margin:0 0 8px}p{margin:0;color:#4a5a6a}</style></head>
<body><div><h1>$n</h1><p>Site ativo com PHP $v. Substitui este ficheiro em $d/public_html.</p></div></body></html>
EOF
}
cmd_site_placeholder_upgrade(){ # troca a página antiga pela nova, só onde o index.html é exatamente o que o painel criou
  local n f v c=0
  for n in $(site_names); do
    f="$WWW_ROOT/$n/public_html/index.html"
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    v=$(grep -o 'Site ativo com PHP [0-9.]*\.' "$f" 2>/dev/null | head -n 1 | sed 's/Site ativo com PHP //; s/\.$//')
    [ -n "$v" ] || continue
    if cmp -s "$f" <(site_placeholder_old "$n" "$v"); then
      site_placeholder > "$f.mp-novo" && chown "mp_$n:mp_$n" "$f.mp-novo" && chmod 640 "$f.mp-novo" && mv -f "$f.mp-novo" "$f" && c=$((c+1))
    fi
  done
  echo "Página \"Brevemente\" atualizada em $c sites (os sites com conteúdo próprio não foram tocados)."
  return 0
}
cmd_site_add(){
  local n="${1:-}" port="" v="$DEFAULT_PHP" key val lo hi re='^[0-9]{1,6}$' adoms="" assl=none
  local -A lims=()
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --port) port="${2:-}"; shift 2 || shift ;;
      --php)  v="${2:-}";    shift 2 || shift ;;
      --domains) adoms="${2:-}"; shift 2 || shift ;;
      --ssl) assl="${2:-}"; shift 2 || shift ;;
      --memory|--upload|--exec|--input-time|--input-vars|--display-errors)
        key=$(lim_opt_key "$1"); val="${2:-}"; shift 2 || shift
        [[ "$val" =~ $re ]] || die "Valor inválido para $key: '$val'"
        if ! lim_check "$key" "$val"; then read -r lo hi <<<"$(lim_range "$key")"; die "$key tem de estar entre $lo e $hi."; fi
        lims[$key]=$val ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  valid_site "$n" || die "Nome inválido. Usa minúsculas, números e '-', a começar por letra (máx. 24)."
  site_exists "$n" && die "O site '$n' já existe."
  id "mp_$n" >/dev/null 2>&1 && die "O utilizador de sistema mp_$n já existe."
  [ -e "$WWW_ROOT/$n" ] && die "A pasta $WWW_ROOT/$n já existe (ficheiros mantidos de um site apagado?)."
  php_is_installed "$v" || die "PHP $v não está instalado. Disponíveis: $(php_installed | tr '\n' ' ')"
  if [ -n "$port" ]; then
    valid_port "$port" || die "Porta inválida: $port"
    port_reserved "$port" && die "A porta $port está reservada."
    port_owner "$port" >/dev/null && die "A porta $port já é usada pelo site '$(port_owner "$port")'."
    port_listening "$port" && die "A porta $port já está em uso por outro serviço."
  else
    port=$(next_port)
  fi

  local u="mp_$n" d="$WWW_ROOT/$n" se=0 fw=0
  useradd -r -U -M -d "$d" -s "$NOLOGIN" -c "MiniPainel site $n" "$u" || die "Não foi possível criar o utilizador $u."
  web_join "$n"
  install -d -o "$u" -g "$u" -m 2750 "$d" "$d/public_html"
  install -d -o "$u" -g "$u" -m 700 "$d/logs" "$d/tmp"
  site_placeholder > "$d/public_html/index.html"
  chown "$u:$u" "$d/public_html/index.html"
  chmod 640 "$d/public_html/index.html"

  cat > "$SITES_DIR/$n.conf" <<EOF
NAME=$n
PORT=$port
PHP=$v
ENABLED=1
SE_PORT=0
FW_PORT=0
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
EOF
  chmod 600 "$SITES_DIR/$n.conf"
  for key in "${!lims[@]}"; do site_set "$n" "$key" "${lims[$key]}"; done

  write_pool "$n" "$v"
  write_fm_pool "$n"
  write_nginx "$n" "$port" "$v" "$NGX_SITES/$n.conf"
  se_restore "$d"
  if se_port_add "$port"; then se=1; fi
  site_set "$n" SE_PORT "$se"

  if ! apply_php "$v" || { [ "$PANEL_PHP" != "$v" ] && ! apply_php "$PANEL_PHP"; }; then
    site_rollback "$n" "$v" "$port" "$se"
    die "Configuração PHP-FPM inválida; nada foi alterado."
  fi
  if ! apply_nginx || ! wait_listen "$port"; then
    site_rollback "$n" "$v" "$port" "$se"
    die "O nginx não conseguiu servir na porta $port; nada foi alterado."
  fi
  if fw_open "$port"; then fw=1; fi
  site_set "$n" FW_PORT "$fw"

  echo "Site '$n' criado na porta $port com PHP $v."
  echo "Pasta: $d/public_html"
  mail_on && mail_site_spool "$n"
  logs_rotate_conf
  if [ -n "$adoms" ]; then ( cmd_site_domains "$n" --set "$adoms" --ssl "$assl" ) 2>&1 || true; fi
  return 0
}

cmd_site_del(){
  local n="${1:-}" keep=0
  [ $# -gt 0 ] && shift
  [ "${1:-}" = "--keep-files" ] && keep=1
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  local v p se fw
  v=$(site_get "$n" PHP); p=$(site_get "$n" PORT); se=$(site_get "$n" SE_PORT); fw=$(site_get "$n" FW_PORT)

  [ "$(site_get "$n" FTP)" = 1 ] && cmd_site_ftp "$n" --off >/dev/null 2>&1
  rm -f "$NGX_SITES/$n.conf" "$NGX_SITES/$n.conf.disabled" "$NGX_INC/mp-$n.inc"
  le_delete "mp-$n"
  ngx_default_sync
  apply_nginx || warn "Verifica o nginx (nginx -t)."
  rm -f "$(php_pool_dir "$v")/mp-$n.conf" "$(fm_pool_file "$n")"
  apply_php "$v" || warn "Verifica o PHP-FPM $v."
  if [ "$PANEL_PHP" != "$v" ]; then apply_php "$PANEL_PHP" || warn "Verifica o PHP-FPM $PANEL_PHP."; fi
  rm -f "/var/lib/minipainel/stats/traffic/$n.csv" "/var/lib/minipainel/stats/traffic/$n.pos"
  rm -rf "/etc/cron.d/minipainel-$n" "${CRON_DIR:?}/$n" "$CRON_DIR/$n.json"; touch /etc/cron.d 2>/dev/null
  rm -rf "${SITE_LOGS:?}/$n" "${CACHE_ROOT:?}/$n"; logs_rotate_conf
  [ "$(site_get "$n" REDIS)" = 1 ] && rds_disable "$n"
  rm -rf "${MSPOOL:?}/$n" "${MLIB:?}/rejected/$n" "$MLIB/rejected/$n.log" "$MLIB/sent/$n"
  if [ -s "$DBMAP" ]; then jq --arg s "$n" 'with_entries(select(.value != $s))' "$DBMAP" > "$DBMAP.tmp" && mv -f "$DBMAP.tmp" "$DBMAP"; fi
  sleep 1
  pkill -u "mp_$n" >/dev/null 2>&1
  userdel "mp_$n" >/dev/null 2>&1 || warn "Não foi possível remover o utilizador mp_$n."
  if getent group "mp_$n" >/dev/null 2>&1; then groupdel "mp_$n" >/dev/null 2>&1; fi

  if [ "$keep" = 1 ]; then
    chown -R root:root "$WWW_ROOT/$n" 2>/dev/null
  else
    rm -rf "${WWW_ROOT:?}/${n:?}"
  fi
  if [ "$se" = 1 ]; then se_port_del "$p"; fi
  if [ "$fw" = 1 ]; then fw_close "$p"; fi
  rm -f "$SITES_DIR/$n.conf"

  if [ "$keep" = 1 ]; then echo "Site '$n' apagado. Ficheiros mantidos em $WWW_ROOT/$n."; else echo "Site '$n' apagado."; fi
  return 0
}

cmd_site_php(){
  local n="${1:-}" nv="${2:-}"
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  php_is_installed "$nv" || die "PHP $nv não está instalado."
  local ov p dest
  ov=$(site_get "$n" PHP); p=$(site_get "$n" PORT); dest=$(ngx_file "$n")
  [ "$ov" = "$nv" ] && die "O site '$n' já usa PHP $nv."

  write_pool "$n" "$nv"
  if ! apply_php "$nv"; then
    rm -f "$(php_pool_dir "$nv")/mp-$n.conf"; apply_php "$nv" >/dev/null 2>&1
    die "Falha ao configurar PHP $nv; nada foi alterado."
  fi
  write_nginx "$n" "$p" "$nv" "$dest"
  if ! apply_nginx; then
    write_nginx "$n" "$p" "$ov" "$dest"; apply_nginx >/dev/null 2>&1
    rm -f "$(php_pool_dir "$nv")/mp-$n.conf"; apply_php "$nv" >/dev/null 2>&1
    die "Falha ao aplicar no nginx; nada foi alterado."
  fi
  rm -f "$(php_pool_dir "$ov")/mp-$n.conf"
  apply_php "$ov" || warn "Verifica o PHP-FPM $ov."
  site_set "$n" PHP "$nv"
  if [ "$(site_get "$n" REDIS)" = 1 ]; then php_has_ext "$nv" redis || { pkg_install_soft "$(php_ext_pkg "$nv" redis)"; apply_php "$nv" >/dev/null 2>&1; }; fi
  cron_write_site "$n"
  echo "Site '$n' passou de PHP $ov para PHP $nv."
  return 0
}

cmd_site_toggle(){
  local n="${1:-}" want="$2"
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  local cur p; cur=$(site_get "$n" ENABLED); p=$(site_get "$n" PORT)
  if [ "$want" = 1 ]; then
    [ "$cur" = 1 ] && die "O site '$n' já está ativo."
    port_listening "$p" && die "A porta $p está agora ocupada por outro serviço."
    mv -f "$NGX_SITES/$n.conf.disabled" "$NGX_SITES/$n.conf" || die "Configuração nginx do site em falta."
    site_set "$n" ENABLED 1; ngx_default_sync
    if ! apply_nginx || ! wait_listen "$p"; then
      mv -f "$NGX_SITES/$n.conf" "$NGX_SITES/$n.conf.disabled"; apply_nginx >/dev/null 2>&1
      die "O nginx não conseguiu servir na porta $p; o site continua desativado."
    fi
    site_set "$n" ENABLED 1
    echo "Site '$n' ativado."
  else
    [ "$cur" = 0 ] && die "O site '$n' já está desativado."
    mv -f "$NGX_SITES/$n.conf" "$NGX_SITES/$n.conf.disabled" || die "Configuração nginx do site em falta."
    site_set "$n" ENABLED 0; ngx_default_sync
    if ! apply_nginx; then
      mv -f "$NGX_SITES/$n.conf.disabled" "$NGX_SITES/$n.conf"; apply_nginx >/dev/null 2>&1
      die "Falha ao desativar; o site continua ativo."
    fi
    site_set "$n" ENABLED 0
    echo "Site '$n' desativado."
  fi
  return 0
}

cmd_site_fixperms(){
  local n="${1:-}"
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  local d="$WWW_ROOT/$n/public_html" u="mp_$n"
  [ -d "$d" ] || die "Pasta em falta: $d"
  web_join "$n"
  chown "$u:$u" "$WWW_ROOT/$n"; chmod 2750 "$WWW_ROOT/$n"
  chown -R "$u:$u" "$d"
  runuser -u "$u" -- find "$d" -type d -exec chmod 2750 {} +
  runuser -u "$u" -- find "$d" -type f -exec chmod 640 {} +
  se_restore "$d"
  apply_nginx >/dev/null 2>&1
  echo "Permissões corrigidas em $d (dono e grupo $u; o nginx lê através do grupo do site)."
  return 0
}

show_limits(){
  local n=$1
  printf 'Limites do site %s\n' "$n"
  printf '  memory_limit          %s MB\n' "$(lim_get "$n" MEM)"
  printf '  upload / post máximo  %s MB\n' "$(lim_get "$n" UPLOAD)"
  printf '  max_execution_time    %s s\n'  "$(lim_get "$n" EXEC)"
  printf '  max_input_time        %s s\n'  "$(lim_get "$n" INPUT_TIME)"
  printf '  max_input_vars        %s\n'    "$(lim_get "$n" INPUT_VARS)"
  printf '  display_errors        %s\n'    "$([ "$(lim_get "$n" DISPLAY_ERRORS)" = 1 ] && echo on || echo off)"
}

cmd_site_limits(){
  local n="${1:-}"
  [ $# -gt 0 ] && shift
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  if [ $# -eq 0 ]; then show_limits "$n"; return 0; fi

  local -A nv=()
  local key val re='^[0-9]{1,6}$' lo hi
  while [ $# -gt 0 ]; do
    case "$1" in
      --memory)         key=MEM ;;
      --upload)         key=UPLOAD ;;
      --exec)           key=EXEC ;;
      --input-time)     key=INPUT_TIME ;;
      --input-vars)     key=INPUT_VARS ;;
      --display-errors) key=DISPLAY_ERRORS ;;
      *) die "Opção desconhecida: $1" ;;
    esac
    val="${2:-}"
    shift 2 2>/dev/null || shift
    [[ "$val" =~ $re ]] || die "Valor inválido para $key: '$val'"
    if ! lim_check "$key" "$val"; then read -r lo hi <<<"$(lim_range "$key")"; die "$key tem de estar entre $lo e $hi."; fi
    nv[$key]=$val
  done

  local f bak v p dest
  f=$(site_conf "$n"); bak="$f.bak"
  cp -p "$f" "$bak" || die "Não foi possível guardar uma cópia da configuração do site."
  for key in "${!nv[@]}"; do site_set "$n" "$key" "${nv[$key]}"; done
  v=$(site_get "$n" PHP); p=$(site_get "$n" PORT); dest=$(ngx_file "$n")
  write_pool "$n" "$v"
  write_nginx "$n" "$p" "$v" "$dest"
  if ! apply_php "$v" || ! apply_nginx; then
    mv -f "$bak" "$f"
    write_pool "$n" "$v"; write_nginx "$n" "$p" "$v" "$dest"
    apply_php "$v" >/dev/null 2>&1; apply_nginx >/dev/null 2>&1
    die "Não foi possível aplicar os limites; foram repostos os anteriores."
  fi
  rm -f "$bak"
  echo "Limites do site '$n' atualizados."
  show_limits "$n"
  return 0
}

# ---------- comandos: bases de dados ----------
db_q(){ mysql -uroot -N -B -e "$1"; }
db_exec(){ printf '%s\n' "$1" | mysql -uroot -N -B; }
db_exists(){ [ "$(db_q "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='$1'" 2>/dev/null)" = 1 ]; }
dbuser_exists(){ local c; c=$(db_q "SELECT COUNT(*) FROM mysql.user WHERE User='$1'" 2>/dev/null); [ -n "$c" ] && [ "$c" != 0 ]; }
db_reserved(){ case " mysql information_schema performance_schema sys mpadmin " in *" $1 "*) return 0 ;; esac; return 1; }
db_sizes(){
  db_q "SELECT s.schema_name, ROUND(COALESCE(SUM(t.data_length+t.index_length),0)/1048576,2)
        FROM information_schema.schemata s
        LEFT JOIN information_schema.tables t ON t.table_schema=s.schema_name
        WHERE s.schema_name NOT IN ('mysql','information_schema','performance_schema','sys')
        GROUP BY s.schema_name ORDER BY s.schema_name" 2>/dev/null
}

cmd_db_list(){
  local n s
  printf '%-34s %s\n' "BASE DE DADOS" "TAMANHO (MB)"
  while IFS=$'\t' read -r n s; do [ -n "$n" ] && printf '%-34s %s\n' "$n" "$s"; done < <(db_sizes)
  return 0
}

# ---------- ficheiros entre sites (o painel tem um só utilizador; cada site continua isolado dos outros) ----------
fm_rel_ok(){ # caminho relativo à raiz do site, sem fugas
  local p=$1
  [[ "$p" == /* ]] && return 1
  [[ "/$p/" == */../* ]] && return 1
  [[ "$p" =~ [[:cntrl:]] ]] && return 1
  return 0
}
fm_freename(){ # pasta nome -> "nome (1).ext" livre
  local d=$1 n=$2 b e i=1
  if [[ "$n" == ?*.* && ! -d "$d/$n" ]]; then b=${n%.*}; e=".${n##*.}"; else b=$n; e=""; fi
  while [ -e "$d/$b ($i)$e" ] || [ -L "$d/$b ($i)$e" ]; do i=$((i+1)); done
  echo "$b ($i)$e"
}
cmd_fm_xfer(){ # origem destino pasta_origem pasta_destino copy|move overwrite|keep|skip item…
  local src="${1:-}" dst="${2:-}" sdir="${3:-}" ddir="${4:-}" mode="${5:-}" conf="${6:-}"
  [ $# -ge 7 ] || die "Uso: mpanel fm-xfer <origem> <destino> <pasta-origem> <pasta-destino> copy|move overwrite|keep|skip <item>…"
  shift 6
  valid_site "$src" && site_exists "$src" || die "O site '$src' não existe."
  valid_site "$dst" && site_exists "$dst" || die "O site '$dst' não existe."
  [ "$src" != "$dst" ] || die "Origem e destino são o mesmo site (usa Mover no próprio site)."
  [[ "$mode" =~ ^(copy|move)$ ]] || die "Operação: copy ou move."
  [[ "$conf" =~ ^(overwrite|keep|skip)$ ]] || die "Se já existir: overwrite, keep ou skip."
  fm_rel_ok "$sdir" && fm_rel_ok "$ddir" || die "Caminho inválido."
  local S D sd dd it f t tmp u="mp_$dst" ok=0 sk=0 need avail
  S=$(realpath -e "$WWW_ROOT/$src") && D=$(realpath -e "$WWW_ROOT/$dst") || die "Pasta do site em falta."
  sd=$(realpath -e "$S/$sdir" 2>/dev/null) || die "A pasta de origem não existe."
  dd=$(realpath -e "$D/$ddir" 2>/dev/null) || die "A pasta de destino não existe."
  [[ "$sd" == "$S" || "$sd" == "$S/"* ]] || die "A pasta de origem está fora do site $src."
  [[ "$dd" == "$D" || "$dd" == "$D/"* ]] && [ -d "$dd" ] || die "A pasta de destino está fora do site $dst."
  for it in "$@"; do [[ -n "$it" && "$it" != */* && "$it" != . && "$it" != .. && ! "$it" =~ [[:cntrl:]] ]] || die "Nome inválido: $it"; done
  # espaço: a cópia é feita antes de apagar a origem (também ao mover)
  need=$(cd "$sd" && du -sb -- "$@" 2>/dev/null | awk '{s += $1} END {print s + 0}')
  avail=$(df -B1 --output=avail "$dd" | tail -n 1 | tr -d ' ')
  [ "$need" -lt $(( avail - 104857600 )) ] || die "Espaço insuficiente no disco: são precisos $(( need / 1048576 )) MB e há $(( avail / 1048576 )) MB livres."
  for it in "$@"; do
    f="$sd/$it"
    if [ -L "$f" ] || [ ! -e "$f" ]; then sk=$((sk+1)); continue; fi   # atalhos e itens que já não existem: ignorados
    t="$dd/$it"
    if [ -e "$t" ] || [ -L "$t" ]; then
      case "$conf" in
        skip) sk=$((sk+1)); continue ;;
        keep) t="$dd/$(fm_freename "$dd" "$it")" ;;
        overwrite) : ;;
      esac
    fi
    tmp="$dd/.mp-copia-$$-$RANDOM"
    if ! cp -a --no-preserve=ownership -- "$f" "$tmp"; then rm -rf -- "$tmp"; die "Falhou a cópia de '$it' (nada foi apagado na origem)."; fi
    find "$tmp" -type l -delete 2>/dev/null                       # atalhos dentro das pastas: não passam para o outro site
    chown -R "$u:$u" "$tmp"
    find "$tmp" -type d -exec chmod 2750 {} + 2>/dev/null; find "$tmp" -type f -exec chmod 640 {} + 2>/dev/null
    [ "$conf" = overwrite ] && { [ -e "$t" ] || [ -L "$t" ]; } && rm -rf -- "$t"
    mv -T -- "$tmp" "$t" || { rm -rf -- "$tmp"; die "Falhou a colocação de '$it' no destino (nada foi apagado na origem)."; }
    [ "$mode" = move ] && rm -rf -- "$f"
    ok=$((ok+1))
  done
  echo "$([ "$mode" = move ] && echo Movidos || echo Copiados) $ok itens ($(( need / 1048576 )) MB) de $src:/$sdir para $dst:/$ddir$([ "$sk" -gt 0 ] && echo "; $sk ignorados (já existiam ou eram atalhos)")."
  return 0
}
