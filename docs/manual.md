# Manual do IDDigital Hosting (MiniPainel) v2.12

## 1. Antes de começar

O IDDigital Hosting (MiniPainel) transforma um servidor Linux num servidor de alojamento completo, gerido por um painel web. Quase tudo se faz no painel; este manual explica o painel e, para quando for preciso, o mínimo de Linux para resolver problemas na consola.

### As peças, em linguagem simples

| Peça | O que é | Analogia |
| --- | --- | --- |
| Servidor | Computador ligado à Internet 24 h por dia, sem ecrã | O edifício |
| Linux (Debian, Ubuntu, AlmaLinux, Rocky) | O sistema operativo do servidor | O Windows, mas sem janelas |
| Painel | Página web onde se gere tudo (sites, email, backups…) | A receção do edifício |
| Consola (terminal) | Janela de texto onde se escrevem comandos | O quadro elétrico |
| root | O administrador do Linux, que pode tudo | O dono das chaves todas |
| Serviço | Programa que corre sempre em segundo plano (nginx, MariaDB, Postfix…) | Um funcionário de turno |
| mpanel | Comando do painel na consola: faz tudo o que o painel faz | O painel, em texto |

### Os serviços que o painel instala

| Serviço | Para que serve |
| --- | --- |
| nginx | Servidor web: entrega os sites aos visitantes |
| PHP-FPM (7.0 a 8.5) | Executa o código PHP dos sites; cada site corre com o seu utilizador |
| MariaDB | Bases de dados (compatível com MySQL) |
| phpMyAdmin | Gestão das bases de dados no browser |
| Postfix | Envio e receção de email (SMTP) |
| Dovecot | Caixas de correio (IMAP e POP3) |
| Rspamd + Redis | Filtro de spam e assinatura DKIM |
| Unbound | Resolver de DNS interno (só para o antispam) |
| Roundcube | Webmail |
| NSD | Servidor DNS autoritativo (opcional) |
| Pure-FTPd | FTPS (opcional) |
| Redis por site | Cache de objetos de cada site (opcional) |
| nftables | Firewall: bloqueios de IPs, gamas e países |
| certbot | Certificados SSL gratuitos (Let's Encrypt) |
| rclone | Envio de backups para destinos remotos |

### Três formas de entrar no servidor

1. **Painel web** (o normal): `https://IP-do-servidor:2443` ou o domínio do painel (ex.: `https://host.iddigital.pt`). Utilizador e password criados na instalação, mais o código de verificação em dois passos.
2. **Terminal do painel** (Sistema → Terminal): consola de root no browser. Exige o 2FA ativo, pede de novo a password e o código, e grava a sessão.
3. **SSH ou consola do Proxmox**: para quando o painel não abre.
   - SSH a partir do Windows: abre o PowerShell e escreve `ssh root@91.209.16.24`.
   - Proxmox: seleciona a máquina virtual → Console. Funciona mesmo sem rede.

Regra de ouro: na consola, **lê o comando antes de carregar em Enter**. Como root, o Linux não pergunta "tem a certeza?".

## 2. Instalação e atualizações

A instalação e as atualizações usam o mesmo instalador; o instalador deteta o que já existe e mantém sites, bases de dados, email e configurações.

### Instalar (servidor novo, como root)

```
wget -O /tmp/install.sh https://raw.githubusercontent.com/naoavr/painel-alojamento-nao/main/install.sh
bash /tmp/install.sh
```

- Sistemas suportados: Debian 12 e 13, Ubuntu 22.04 e 24.04, AlmaLinux e Rocky 9 ou superior.
- No fim, o endereço do painel, o utilizador e a password ficam em `/root/minipainel-credenciais.txt`. Guarda-os num gestor de passwords e apaga o ficheiro.
- Opções: `--php "7.4 8.3 8.4"` (escolher versões de PHP; por omissão 7.0 a 8.5) e `--panel-port 2443`.
- Com o repositório privado, o `wget` acima precisa do token: `wget --header="Authorization: Bearer github_pat_…" -O /tmp/install.sh …`.

### Atualizar o painel

- **Pelo painel (recomendado):** Sistema → Atualizações → Painel → **Procurar atualizações** → **Atualizar**. Antes de instalar, o painel guarda uma cópia da versão atual e, se o painel não responder depois, repõe a anterior sozinho.
- **Pela consola:** o mesmo comando da instalação.
- **Repor uma versão anterior:** Atualizações → Painel → Cópias anteriores → **Repor** (pede password e código). A conta de acesso e o 2FA nunca são repostos.

### Repositório privado no GitHub

O repositório pode ficar sempre privado. O painel usa um token só de leitura:

1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token.
2. Repository access: **Only select repositories** → o repositório do painel. Permissions → Contents: **Read-only**.
3. Copia o token (`github_pat_…`) e cola-o em Sistema → Atualizações → **Repositório no GitHub** (pede password e código). Fica guardado só para o root.

### Publicar uma versão nova

Basta enviar o `install.sh` novo para o repositório (GitHub → Add file → Upload files → Commit). A linha `# NOTAS: …` no início do ficheiro aparece no painel como "o que mudou". O `version.json` é opcional: sem ele, o painel lê a versão diretamente do `install.sh`.

### Assinatura das atualizações (opcional)

Sem chave configurada, o botão Atualizar pede confirmação com o SHA-256 à vista. Para exigir assinatura:

1. No teu computador (nunca no servidor): `bash minipainel-release.sh keygen` → copia a chave pública.
2. No painel: Atualizações → Chave de assinatura → cola a chave → Guardar.
3. Em cada versão: `bash minipainel-release.sh sign install.sh "o que mudou"` e envia `install.sh`, `install.sh.sig` e `version.json`.

Guarda uma cópia da chave privada (`~/.iddigital-hosting/update-signing.key`) num sítio seguro e offline.

### Atualizações do sistema operativo

Atualizações → separador **Sistema operativo**: mostra os pacotes disponíveis (os de segurança à parte), instala-os e permite ativar a instalação automática das de segurança. Se o sistema pedir reinício, aparece um aviso com o botão **Reiniciar**.

## 3. Primeiros passos no painel

Depois do primeiro login, faz estas cinco coisas por esta ordem: ativar o 2FA, escolher o modo do servidor, definir o domínio do painel, restringir o acesso e configurar os alertas.

### O menu

| Onde | Páginas |
| --- | --- |
| Barra lateral · Geral | Resumo (estado geral) · Recursos (CPU, RAM, disco, rede, gráficos) |
| Barra lateral · Alojamento | Sites · Ficheiros · Logs · Tarefas agendadas · Email · DNS · Bases de dados · phpMyAdmin · PHP |
| Canto superior direito · **Manual** | Este manual, com índice e pesquisa |
| Canto superior direito · **Sistema** | Serviços · Sentinela · Processos · Ligações · Alertas · Terminal · Backups · Auditoria · Atualizações |
| Canto superior direito · menu do utilizador | Conta e segurança · Definições · Sair |

As ações demoradas (criar um site, emitir um certificado) entram numa fila: aparece uma notificação quando terminam. Não é preciso ficar na página. Depois de guardar, ficas no mesmo separador da página.

### 1. Ativar a verificação em dois passos (2FA)

Menu do utilizador → Conta e segurança → Verificação em dois passos.

1. Lê o código QR com uma aplicação de autenticação (Google Authenticator, Microsoft Authenticator, 2FAS, Bitwarden…).
2. Escreve o código de 6 dígitos para confirmar.
3. **Guarda os 8 códigos de recuperação** fora do servidor. Cada um serve uma vez, se perderes o telemóvel.

Sem 2FA, o Terminal do painel não abre.

### 2. Modo do servidor (Definições → Servidor e domínio)

- **LAN:** cada site abre por IP e porta (ex.: `http://10.0.0.20:8001`). Para redes internas e testes.
- **Internet:** cada site abre pelo seu domínio, com certificado Let's Encrypt automático. Indica também o email que recebe os avisos dos certificados.

Mudar de modo não altera os sites existentes; cada site continua acessível também pela porta.

### 3. Domínio do painel (Definições → Servidor e domínio)

Permite abrir o painel por um nome (ex.: `https://host.iddigital.pt`) com certificado válido. O nome tem de ter um registo A a apontar para o IP do servidor.

### 4. Restringir o acesso (Definições → Acesso e segurança)

- **IPs autorizados no painel:** se preencheres, o painel (e o phpMyAdmin e os ficheiros) só abre a partir desses IPs ou redes (ex.: `89.155.10.20` ou `192.168.1.0/24`). O teu IP atual tem de estar na lista.
- **Acesso pelas portas dos sites:** "Só rede local" fecha as portas próprias (`:8001`…) à Internet, deixando só os domínios com HTTPS.
- **Proteção contra força bruta:** limites de passwords erradas (SSH, painel, email, FTP) e duração dos bloqueios.

### 5. Alertas (Sistema → Alertas)

Configura o SMS (bulksms.com) e o email, e carrega em **Enviar mensagem de teste**. Sem isto, o Sentinela e os limites de recursos não te conseguem avisar.

## 4. Sites

Cada site é isolado dos outros: tem o seu utilizador no sistema (`mp_<site>`), a sua pasta, o seu PHP e a sua porta. Um site comprometido não consegue ler os ficheiros dos outros.

### Criar um site

Sites → **Novo site**: nome (letras minúsculas, números e hífens, ex.: `loja`), versão de PHP e, opcionalmente, os domínios.

- Pasta pública: `/srv/www/loja/public_html` (é aqui que se põem os ficheiros do site).
- Também ficam `/srv/www/loja/logs` (erros do PHP, tarefas) e `/srv/www/loja/tmp`.
- O site abre logo em `http://IP:porta` (ex.: `:8001`).

### Domínios e SSL

Sites → ⋮ → **Domínios e SSL**.

1. Antes, cria no DNS do domínio um registo **A** para cada nome (ex.: `loja.pt` e `www.loja.pt`) com o IP do servidor. Confirma com `dig +short loja.pt`.
2. No painel, indica os domínios, escolhe **Let's Encrypt** e guarda. O certificado é emitido e renovado sozinho.
3. Opções: forçar HTTPS e preferir o endereço com ou sem `www`.

Se aparecer "Sem certificado · pedir novamente" na lista, o pedido falhou (quase sempre porque o DNS ainda não aponta para o servidor). Corrige o DNS e carrega em Guardar outra vez.

Cuidados que fazem o certificado falhar: um registo **AAAA** (IPv6) a apontar para outro servidor; um registo **CAA** que não autoriza `letsencrypt.org`; o proxy da Cloudflare ligado (desliga-o enquanto emites).

### Outras opções do menu ⋮ de cada site

| Opção | O que faz |
| --- | --- |
| Mudar PHP | Troca a versão de PHP do site (7.0 a 8.5). As versões 7.x e 8.0/8.1 já não têm suporte de segurança |
| Limites | Memória, tamanho de upload, tempo de execução, variáveis de formulário, mostrar erros |
| Desempenho | Cache de página, Redis, processos PHP, scripts lentos, cache no browser e WebP (secção 16) |
| Acesso FTP/SFTP | Uma conta por site: FTPS (porta 21, utilizador `loja`) e SFTP (porta 22, utilizador `mp_loja`), com a mesma password; fechada na pasta do site |
| Ficheiros | Abre o gestor de ficheiros na pasta do site (editar, enviar, descarregar, comprimir) |
| Tarefas agendadas | Cron do site: comandos ou URLs a horas certas, com a saída guardada |
| Logs | Acessos, erros do servidor, erros do PHP, PHP lento e saída das tarefas |
| Corrigir permissões | Repõe o dono e as permissões corretos de todos os ficheiros do site |
| Desativar / Ativar | Põe o site offline sem apagar nada |
| Apagar | Apaga o site (com opção de manter os ficheiros) |

### Versões de PHP e extensões

Página **PHP**: versões instaladas, estado de cada serviço, sites por versão, data de fim de suporte e o OPcache. Em "Extensões" instalas extensões opcionais por versão (imagick, redis, memcached, gmp, apcu…). Para acrescentar versões: `bash /tmp/install.sh --php "…"` com todas as versões que queres manter.

### Ficheiros, FTP e SFTP

- **Gestor de ficheiros** (página Ficheiros): editar, enviar (inclui ficheiros grandes), descarregar, comprimir e descomprimir. Corre com o utilizador do site, por isso os ficheiros ficam sempre com o dono certo.
- **FileZilla com FTPS:** servidor = IP ou domínio, porta 21, "Requer FTP explícito sobre TLS", utilizador `loja`.
- **FileZilla com SFTP:** protocolo SFTP, porta 22, utilizador `mp_loja`.
- Servidor atrás de NAT: preenche o IP público em Definições → Serviços → FTP e reencaminha as portas 21 e 30000–30100.

### Tarefas agendadas (cron)

Página Tarefas agendadas → **Nova tarefa**: site, quando (cada minuto, hora, dia… ou expressão cron) e o comando ou URL. Cada tarefa corre com o utilizador do site, nunca duas vezes em simultâneo, e a saída fica em Logs → Tarefas agendadas. Botão **Executar agora** para testar.

## 5. Bases de dados e phpMyAdmin

Cada base de dados tem o seu utilizador próprio e só aceita ligações do próprio servidor (`localhost`); ninguém de fora lhe consegue ligar.

### Criar e gerir

Bases de dados → **Nova base de dados**: nome, utilizador e password (vazio = gerada). Opções no ⋮:

- **Associar a um site:** a base entra nos backups desse site.
- **Mudar password** do utilizador.
- **Apagar** (pede confirmação).

Na aplicação (WordPress, PrestaShop…) usa: servidor `localhost`, porta `3306`, o nome da base, o utilizador e a password.

### phpMyAdmin

Barra lateral → **phpMyAdmin** (abre noutro separador, já autenticado pelo painel). Entra com o utilizador e a password da base, ou com a conta de administrador do MariaDB indicada em Bases de dados.

Tempos e limites (sessão, tempo por operação, tamanho máximo de importação): Definições → Serviços → phpMyAdmin.

### Importar uma base de dados grande

O phpMyAdmin serve para ficheiros até ao limite definido. Para ficheiros grandes, a consola é mais rápida e não tem limite:

```
mysql -uroot nome_da_base < /caminho/backup.sql
zcat /caminho/backup.sql.gz | mysql -uroot nome_da_base
```

Para exportar: `mysqldump -uroot nome_da_base | gzip > /root/nome_da_base.sql.gz`

### Erro "Collation desconhecida: utf8mb4_0900_ai_ci"

Acontece com ficheiros exportados de um **MySQL 8**. Troca a collation antes de importar:

```
sed -i -E 's/utf8mb4_0900_(ai_ci|as_ci|as_cs|bin)/utf8mb4_unicode_ci/g' /caminho/backup.sql
```

### Comandos úteis

| Para | Comando |
| --- | --- |
| Entrar na consola do MariaDB | `mysql -uroot` |
| Ver as bases de dados | `mysql -uroot -e 'SHOW DATABASES'` |
| Consultas a correr agora | `mysql -uroot -e 'SHOW FULL PROCESSLIST'` |
| Estado do serviço | `systemctl status mariadb` |
| Reiniciar | `systemctl restart mariadb` |

## 6. Email

O email completo (receção, envio, caixas, webmail e antispam) ativa-se com um nome de servidor, por exemplo `host.iddigital.pt`. Esse nome tem de ter um registo A a apontar para o servidor e, idealmente, o PTR (DNS inverso) com o mesmo nome.

### Ativar

Página Email → Ativar, ou na consola: `mpanel mail-enable --host host.iddigital.pt`. Para **mudar o nome** mais tarde, corre o mesmo comando com o nome novo: as caixas, as mensagens e o DKIM mantêm-se.

Portas que têm de estar acessíveis: 25 (receção), 465 e 587 (envio), 993 e 995 (IMAP e POP3 com SSL), 2096 (webmail). A porta 25 de **saída** tem de estar desbloqueada no fornecedor; testa com `nc -vz gmail-smtp-in.l.google.com 25`.

### Domínios, caixas e aliases

Separador **Domínios e caixas**:

1. **Adicionar domínio** (ex.: `pontoderede.pt`). Cada domínio recebe a sua chave DKIM.
2. Em ⋮ → **Registos DNS** aparecem os registos a criar no DNS do domínio; depois carrega em **Verificar** até ficarem todos "OK".
3. **Nova caixa:** endereço, password e quota.
4. **Aliases:** reencaminhamentos (ex.: `geral@` → `joao@` e `maria@`).

Registos típicos (o painel mostra os valores exatos, incluindo a chave DKIM):

| Nome | Tipo | Valor |
| --- | --- | --- |
| `pontoderede.pt` | MX | `10 host.iddigital.pt` |
| `pontoderede.pt` | TXT | `v=spf1 mx a:host.iddigital.pt ~all` |
| `mp._domainkey.pontoderede.pt` | TXT | `v=DKIM1; k=rsa; p=…` (copiar do painel) |
| `_dmarc.pontoderede.pt` | TXT | `v=DMARC1; p=quarantine; …` |

Só pode haver **um** registo SPF por domínio. O **PTR** do IP pede-se ao fornecedor do IP; sem ele, Gmail e Outlook mandam as mensagens para o spam.

Antes de mudar o MX de um domínio que já tem email noutro servidor, cria as caixas aqui e migra as mensagens antigas.

### Configurar um programa de email

| Ligação | Servidor | Porta | Segurança |
| --- | --- | --- | --- |
| Entrada (IMAP) | `host.iddigital.pt` | 993 | SSL/TLS |
| Entrada (POP3) | `host.iddigital.pt` | 995 | SSL/TLS |
| Saída (SMTP) | `host.iddigital.pt` | 465 (SSL) ou 587 (STARTTLS) | autenticação obrigatória |

Utilizador = endereço completo; password = a da caixa.

### Webmail

`https://host.iddigital.pt:2096`. Em Definições → Respostas automáticas configuram-se férias e ausências; em Filtros, regras próprias. Mover uma mensagem para o Lixo ensina o filtro de spam; tirá-la de lá também.

### Envio dos sites

O `mail()` do PHP de cada site passa por um controlo próprio: o remetente tem de ser de um domínio do site, há um limite de mensagens por hora e no máximo 50 destinatários por mensagem. Um site que comece a enviar spam é **suspenso automaticamente**. Separador **Envio dos sites**: limites, suspender, retomar e limpar a fila de cada site.

### Antispam, listas e fila

- **Spam e listas:** permitir ou bloquear um endereço, um domínio (`@dominio.pt`) ou um IP; histórico de mensagens rejeitadas.
- **Antispam:** listas negras (DNSBL), limites, antivírus ClamAV (opcional, consome cerca de 1 GB de RAM).
- **Fila:** mensagens à espera de entrega, com reenviar e apagar.

### Comandos úteis

| Para | Comando |
| --- | --- |
| Ver a fila | `postqueue -p` |
| Tentar entregar já | `postqueue -f` |
| Seguir o registo do email em direto | `journalctl -f -u postfix -u dovecot` |
| Procurar o que aconteceu a um endereço | `journalctl -u postfix --since today \| grep cliente@exemplo.pt` |
| Verificar os registos DNS de um domínio | `mpanel mail-dns-check pontoderede.pt` |
| Testar a receção do exterior | `nc -vz host.iddigital.pt 25` (a partir de outro computador) |

## 7. DNS

O DNS diz à Internet para onde vai cada nome (`loja.pt` → IP do servidor). Há duas formas de o gerir: num serviço externo (ISPmanager, registador, Cloudflare), que é o mais simples, ou no próprio servidor, com a página DNS.

### Opção A: DNS externo (recomendado com um só servidor)

Nos nameservers onde o domínio está, cria um registo A para cada nome que uses (domínio, `www`, subdomínios) com o IP do servidor. Um registo genérico `*.host` cobre todos os subdomínios de `host.iddigital.pt` de uma vez. Os registos do email (MX, SPF, DKIM, DMARC) também se criam lá.

### Opção B: DNS neste servidor (página DNS) — servidor autónomo

A página DNS tem dois separadores: **Domínios** (os teus domínios e os seus registos) e **Servidor DNS** (o próprio servidor).

**Pôr o servidor a funcionar (uma vez):**

1. Separador **Servidor DNS** → indica os dois nameservers (ex.: `ns1.host.iddigital.pt` e `ns2.host.iddigital.pt`), o IP público e o email do responsável. O painel instala o NSD, que só responde pelas tuas zonas (nunca resolve domínios de terceiros).
2. Na zona onde esses nomes vivem (ex.: `iddigital.pt`, no ISPmanager), cria `ns1.host` e `ns2.host` como registos A com o IP do servidor.
3. Carrega em **Verificar agora**: todos os testes devem ficar OK (serviço a correr, nameservers visíveis na Internet, resposta por UDP e TCP, transferência de zona recusada, sem resolver aberto). A porta 53 (UDP e TCP) tem de estar aberta na firewall do Proxmox e do fornecedor.

**Cada domínio:**

1. Separador **Domínios** → **Adicionar domínio**. Os registos do site, do email (MX, SPF, DKIM, DMARC) e um CAA para o Let's Encrypt são criados sozinhos.
2. No registador, muda os nameservers do domínio para `ns1…` e `ns2…` (nos `.pt`, cria primeiro a zona aqui: o DNS.PT verifica-a antes de aceitar a mudança).
3. Abre o domínio → **Verificar nameservers**: o estado passa de "Pendente" a "Ativo".

Com um só servidor, os dois nameservers apontam para a mesma máquina: se o servidor parar, os domínios deixam de resolver (incluindo o email).

### Gerir os registos de um domínio

Abre o domínio (**Gerir DNS**). Funciona como no Cloudflare:

- **Adicionar:** no topo, escolhe o tipo, o nome (`@` = o próprio domínio, ou `www`, `loja`…), o conteúdo e o TTL (**Auto** usa o valor predefinido do servidor). Os campos e a ajuda mudam com o tipo (o MX e o SRV pedem prioridade).
- **Editar / Apagar:** em cada linha. Os registos marcados **painel** são criados a partir dos sites e do email; se os editares ou apagares, passam a ser teus e o painel deixa de os alterar.
- **Procurar e filtrar** por tipo ou texto.
- **Verificar propagação:** compara o que este servidor responde com o que a Internet (Google, 8.8.8.8) vê — "Igual", "Diferente" ou "Ainda não".
- **Mais →**
  - **Email do domínio:** *Este servidor*, *Google Workspace* ou *Microsoft 365* (troca o MX e o SPF; no Microsoft 365 também cria o `autodiscover`).
  - **Exportar / Importar zona (BIND):** para levar ou trazer domínios de outros sistemas (ISPmanager, Cloudflare). Na importação, os registos repetidos são ignorados e o SOA/NS vêm deste servidor.
  - **Repor registos predefinidos:** volta a pôr os registos do site e do email como o painel os cria.

| Tipo | Para que serve | Exemplo de conteúdo |
| --- | --- | --- |
| A | Nome → IPv4 | `91.209.16.24` |
| AAAA | Nome → IPv6 | `2a01:…` |
| CNAME | Nome → outro nome (nunca em `@`) | `loja.pt` |
| MX | Servidor de email do domínio | `host.iddigital.pt` (prioridade 10) |
| TXT | Texto (SPF, DKIM, verificações Google/Microsoft) | `v=spf1 mx ~all` |
| NS | Delegar um subdomínio | `ns1.outro.pt` |
| SRV | Serviços (VoIP, Teams…) | `5 5060 sip.loja.pt` (prioridade 10) |
| CAA | Quem pode emitir certificados | `0 issue "letsencrypt.org"` |

Cada alteração é verificada antes de ser ativada: um registo inválido é recusado e a zona fica como estava.

### Valores predefinidos (Servidor DNS)

TTL predefinido (o "Auto" dos registos) e os tempos do SOA (refresh, retry, expire, TTL negativo) de todas as zonas. Os valores de origem servem para quase todos os casos.

### Testar o DNS

| Para | Comando |
| --- | --- |
| Para onde aponta um nome (Google) | `dig +short loja.pt @8.8.8.8` |
| Que nameservers tem um domínio | `dig +short NS loja.pt @8.8.8.8` |
| O que responde este servidor | `dig +short loja.pt @91.209.16.24` |
| Registos de email | `dig +short MX loja.pt` · `dig +short TXT loja.pt` |
| Estado do NSD | `systemctl status nsd` |
| Verificar uma zona | `nsd-checkzone loja.pt /etc/nsd/zones/loja.pt.zone` |

Depois de criar ou mudar um registo, o resto da Internet pode demorar até 1 hora a vê-lo (cache). No Windows, `ipconfig /flushdns` limpa a cache do teu computador.

## 8. Backups e restauro

Todos os dias às 03:00 o painel faz backup de cada site (ficheiros, bases de dados associadas e tarefas agendadas), de cada base de dados e da configuração do sistema. Os backups são assinados, para que um ficheiro alterado nunca seja reposto.

### Onde ficam e quanto tempo

- Local: `/var/backups/minipainel/` (uma pasta por site, mais `_bd`, `_sistema` e `_atualizacoes`).
- Retenção (Sistema → Backups → Agendamento e destinos): por omissão 7 diários, 4 semanais e 6 mensais.
- **Cópia remota** (recomendado): SFTP, S3 (Backblaze, Wasabi, MinIO, AWS…) ou outro destino do rclone. Os backups enviados para fora são **cifrados (AES-256)** antes de saírem do servidor.

### A chave dos backups: guarda-a fora do servidor

A chave `/etc/minipainel/backup.key` assina e cifra os backups. Se o servidor se perder, **sem esta chave os backups remotos não se conseguem abrir**. Em Backups → Agendamento e destinos → **Mostrar chave**, copia-a para o teu gestor de passwords.

### Fazer um backup agora

Sistema → Backups → **Fazer backup** → escolhe um site (ou todos) e, se quiseres, envia também para um destino remoto. O progresso aparece no topo da página. O painel continua a responder durante o backup.

### Restaurar

Backups → Cópias → linha do backup → **Restaurar**. Podes repor tudo, só os ficheiros ou só as bases de dados. O painel verifica a assinatura antes de repor. Cada backup também se pode **descarregar** (ficheiros em `.tar.gz` e bases em `.sql.gz`).

### Destinos remotos

Backups → Agendamento e destinos → **Novo destino**:

| Tipo | O que precisas |
| --- | --- |
| SFTP | Servidor, porta, utilizador, password ou chave SSH, pasta |
| S3 | Fornecedor, access key, secret key, endpoint (se não for AWS), região, bucket/pasta |

Depois de criar, carrega em **Testar**: o painel escreve e apaga um ficheiro no destino para confirmar.

### Comandos úteis

| Para | Comando |
| --- | --- |
| Fazer backup de tudo agora | `mpanel backup-run` |
| Só de um site, e enviar para um destino | `mpanel backup-run --site loja --remote caixa` |
| Listar os backups | `mpanel bk-list` |
| Ver a chave dos backups | `mpanel bk-key` |
| Espaço ocupado pelos backups | `du -sh /var/backups/minipainel/*` |

Testa um restauro de vez em quando (por exemplo, para um site de teste). Um backup que nunca foi reposto é uma esperança, não uma garantia.

## 9. Segurança

A segurança assenta em camadas: cada site isolado, o painel com 2FA, bloqueios automáticos de quem tenta adivinhar passwords, e uma firewall que bloqueia IPs, gamas e países. Nunca são bloqueados o próprio servidor, os IPs de confiança e os IPs de onde usaste o painel nos últimos 7 dias.

### Página Ligações (Sistema → Ligações)

| Separador | Para que serve |
| --- | --- |
| Ligações ativas | Cada IP ligado agora, com o país, o número de ligações e o serviço (HTTPS, SSH, SMTP…); botão Bloquear |
| Países | De onde vêm as ligações (percentagens) e bloqueio de países inteiros |
| Bloqueios | IPs e gamas bloqueados (ex.: `45.148.10.0/24`), com o motivo e a expiração; IPs de confiança |
| Proteção e limites | Limite de ligações com reserva para Portugal; bloqueio automático por IP |

### Bloquear

- **Um IP ou uma gama:** Ligações → **Bloquear IP ou gama** → duração (1 hora, 24 horas, 7 dias, permanente). O bloqueio vale para todas as portas, incluindo SSH, e corta as ligações abertas.
- **Um país:** Ligações → Países → escolher → **Bloquear país**. Só afeta ligações novas; as respostas às ligações feitas pelo servidor continuam a passar. Cuidado: bloquear os EUA, por exemplo, impede o Let's Encrypt, o Google e notificações de pagamentos.
- **IPs de confiança** (Ligações → Bloqueios): nunca são bloqueados por nada. Põe aqui o IP fixo do escritório.

### Limite de ligações com reserva para Portugal

Quando as ligações chegam a 80% da capacidade, o servidor entra em **modo de proteção**: recusa ligações novas de fora de Portugal e continua a aceitar Portugal, a rede local, os IPs de confiança e o DNS. Sai do modo quando a carga fica abaixo de 60% durante 2 minutos. Cada mudança gera um alerta. Percentagens, capacidade e país: Ligações → Proteção e limites.

### Proteção contra força bruta

Definições → Acesso e segurança. Ao fim de várias passwords erradas num intervalo (por omissão 10 minutos), o IP é bloqueado:

| Serviço | Falhas até bloquear (omissão) |
| --- | --- |
| SSH (todas as contas, incluindo root) | 5 |
| Painel (password ou código 2FA) | 10 |
| Email, webmail e FTP | 10 |

Reincidentes em 30 dias ficam bloqueados mais tempo: 1 hora, depois 24 horas, depois 7 dias (configurável).

### Boas práticas

- 2FA ativo e códigos de recuperação guardados fora do servidor.
- IPs autorizados no painel, se tiveres IP fixo.
- **SSH só com chave:** depois de confirmares que entras com a tua chave SSH, em `/etc/ssh/sshd_config` define `PermitRootLogin prohibit-password` e reinicia com `systemctl restart ssh`. A consola do Proxmox continua a aceitar a password.
- Passwords longas e diferentes para cada caixa de email e base de dados.
- PHP atualizado nos sites (as versões 7.x já não recebem correções de segurança).
- Atualizações de segurança do sistema automáticas (Atualizações → Sistema operativo).

### Terminal do painel

Sistema → Terminal abre uma consola de root no browser. Só funciona com o 2FA ativo, pede de novo a password e o código, fecha ao fim de 15 minutos sem atividade e **grava tudo o que aparece no ecrã** durante 90 dias (página Terminal → Sessões gravadas). Cada abertura aceita uma ligação: recarregar a página fecha o terminal, e o painel volta sozinho ao botão **Abrir terminal**. Cola os comandos um de cada vez (ou numa linha com `;`).

### Auditoria

Sistema → Auditoria: todos os inícios de sessão e ações feitas no painel, com data, utilizador e IP. Também ficam no journal do sistema: `journalctl -t minipainel-audit`.

## 10. Vigilância: Sentinela, Alertas, Processos e Logs

O servidor vigia-se sozinho: o Sentinela testa todos os serviços a cada minuto e repara o que falha, os Alertas avisam por SMS e email, e as páginas Processos e Logs mostram o que se passa.

### Sentinela (Sistema → Sentinela)

- **Estado:** cada teste a verde (OK), amarelo (aviso) ou vermelho (falha), por grupo: Serviços, Sites, Email, DNS, Certificados, Sistema e Painel. **Testar agora** corre todos os testes de imediato.
- **Incidentes:** o que falhou, quando, quanto durou e se foi reparado sozinho.
- **Disponibilidade:** barra dos últimos 30 dias por teste.
- **Configuração:** reparação automática (reinicia o serviço até 3 vezes por hora, e confirma), testar a página inicial dos sites, desligar testes que não se aplicam.

Erros das aplicações (um erro 500 num site) só geram alerta: reiniciar serviços não os resolve. O Sentinela e o recolhedor de estatísticas vigiam-se um ao outro.

### Alertas (Sistema → Alertas)

| Alerta | Quando (por omissão) |
| --- | --- |
| CPU | Acima de 90% durante 5 minutos |
| RAM | Acima de 90% durante 5 minutos |
| Disco | Acima de 90% |
| Ligações | Acima de 70% da capacidade durante 2 minutos |
| Modo de proteção | Sempre que entra ou sai |
| Volume de email | Depois de 30 dias a aprender o normal: uma hora com mais 20% (e pelo menos mais 50 mensagens) |
| Sentinela | Falha, reparação automática e regresso ao normal |

Cada problema gera um alerta, um aviso quando volta ao normal e um lembrete a cada 6 horas se continuar. O histórico mostra se o SMS e o email foram entregues.

### Processos (Sistema → Processos)

Mostra o que consome CPU e memória, agrupado por origem: **cada site** (ex.: "Site loja"), Email, Base de dados, Servidor web, PHP, Painel e Sistema operativo. Na lista, **Terminar** pede ao processo que pare e **Forçar** termina-o de imediato. Num processo de um site há também "Terminar todos os processos deste site" (útil para um script em ciclo). Os processos essenciais do servidor estão protegidos.

### Logs (Alojamento → Logs, ou ⋮ de cada site)

| Separador | O que mostra | Onde está o ficheiro |
| --- | --- | --- |
| Acessos | Cada pedido: IP, página, código, tempo, cache; resumo das 24 h e páginas mais lentas | `/var/log/minipainel/sites/<site>/access.log` |
| Erros do servidor | Erros do nginx | `/var/log/minipainel/sites/<site>/error.log` |
| Erros do PHP | Avisos e erros fatais do PHP | `/srv/www/<site>/logs/php-error.log` |
| PHP lento | Ficheiro, função e linha dos pedidos demorados | `/var/log/minipainel/sites/<site>/php-slow.log` |
| Tarefas agendadas | Saída de cada tarefa | `/srv/www/<site>/logs/cron-<id>.log` |

"Ao vivo" mostra as linhas novas sozinhas. Os logs ficam 90 dias, rodados e comprimidos todos os dias.

Como ler os códigos HTTP: **2xx** correu bem; **3xx** redirecionamento; **404** página não existe; **403** proibido; **500** erro do código do site (vê "Erros do PHP"); **502** o PHP do site não respondeu (vê o Sentinela e o serviço PHP); **504** o PHP demorou demasiado.

### Recursos e Resumo

Resumo: estado geral, sites e serviços. Recursos: gráficos de CPU, RAM, disco, rede e carga (última hora, 24 horas, 7 dias, 30 dias) e o consumo de cada site.

## 11. Mapa de ficheiros e pastas

Regra geral: o que o painel gera não se edita à mão (é reescrito na alteração seguinte). Muda pelo painel ou pelo `mpanel`. Os ficheiros marcados com "segredo" nunca se partilham.

### Dados dos sites e do email

| Caminho | O que é |
| --- | --- |
| `/srv/www/<site>/public_html` | Ficheiros públicos do site |
| `/srv/www/<site>/logs` | Erros do PHP e saída das tarefas do site |
| `/srv/www/<site>/tmp` | Temporários, sessões e a socket do Redis do site |
| `/var/mail/vhosts/<domínio>/<caixa>/Maildir` | Mensagens de cada caixa de correio |
| `/var/lib/mysql` | Dados das bases de dados (não mexer; usa o mysqldump) |
| `/var/backups/minipainel` | Backups locais |
| `/var/log/minipainel/sites/<site>` | Logs de acessos, erros do nginx e PHP lento de cada site |
| `/var/log/minipainel/terminal` | Gravações das sessões do Terminal |
| `/var/cache/minipainel/fcgi/<site>` | Cache de página de cada site |

### Configuração do painel (`/etc/minipainel`)

| Ficheiro | O que guarda |
| --- | --- |
| `minipainel.conf` | Configuração geral (porta do painel, PHP do painel…) |
| `server.conf` | Modo LAN/Internet, domínio do painel, IPs autorizados, países bloqueados, limite de ligações, OPcache, MariaDB, Brotli, rede |
| `sites/<site>.conf` | Configuração de cada site (porta, PHP, domínios, limites, desempenho) |
| `backup.conf` · `backup-remotes.json` · `rclone.conf` | Agendamento, destinos e credenciais dos backups (segredo) |
| `backup.key` | Chave que assina e cifra os backups (segredo; guardar fora do servidor) |
| `mail.conf` · `mail/data.json` | Configuração do email; domínios, caixas e aliases |
| `dns.conf` · `dns/<zona>.json` | DNS: nameservers e zonas |
| `alerts.conf` | SMS e email dos alertas, limites (segredo: token da bulksms) |
| `protect.conf` · `sentinel.conf` | Proteção contra força bruta; Sentinela |
| `ftp.conf` · `pma.conf` · `redis/<site>.conf` | FTP, phpMyAdmin e Redis de cada site |
| `update.conf` · `update.token` · `update.pub` | Endereço das atualizações, token do GitHub (segredo) e chave pública |
| `redis.pw` · `rspamd-controller.pw` · `webmail.key` | Passwords internas do email (segredo) |
| `version` | Versão instalada |

### Programas do painel

| Caminho | O que é |
| --- | --- |
| `/usr/local/sbin/mpanel` | Comando principal (tudo o que o painel faz) |
| `/usr/local/sbin/mpanel-stats` | Recolhedor de estatísticas (corre sempre) |
| `/usr/local/sbin/mpanel-cron` · `mp-sendmail` · `mpanel-term` | Tarefas dos sites, envio de email dos sites, sessões do Terminal |
| `/opt/minipainel/public/index.php` | O painel web |
| `/opt/minipainel/manual.md` | Este manual |
| `/opt/minipainel/phpmyadmin` | phpMyAdmin |
| `/var/lib/minipainel` | Estado do painel: conta de acesso (`auth.json`), fila de tarefas, estatísticas, auditoria |

### Configuração dos serviços (gerada pelo painel)

| Caminho | Serviço |
| --- | --- |
| `/etc/nginx/minipainel/` | nginx: painel, sites, cache e compressão |
| `/etc/php/<versão>/fpm/pool.d/mp-<site>.conf` | PHP de cada site (no AlmaLinux: `/etc/opt/remi/php<vv>/php-fpm.d/`) |
| `/etc/php/<versão>/fpm/conf.d/99-minipainel.ini` | OPcache |
| `/etc/mysql/mariadb.conf.d/90-minipainel.cnf` | Afinação do MariaDB |
| `/etc/postfix/` · `/etc/dovecot/` · `/etc/rspamd/local.d/` | Email |
| `/etc/nsd/` | DNS |
| `/etc/letsencrypt/live/mp-<nome>/` | Certificados SSL |
| `/etc/sysctl.d/90-minipainel-net.conf` | Afinação de rede (BBR) |
| `/etc/cron.d/minipainel-*` | Tarefas automáticas do painel (backups, atualizações, Sentinela, países, WebP) |

Antes de editar qualquer ficheiro à mão, faz uma cópia: `cp ficheiro ficheiro.bak`.

## 12. Comandos mpanel

O `mpanel` faz na consola tudo o que o painel faz, e é a forma de resolver as coisas quando o painel não abre. Corre-se como root. `mpanel help` mostra a lista completa com todas as opções.

### Sites e PHP

| Comando | O que faz |
| --- | --- |
| `mpanel site-list` | Lista os sites, portas, PHP e estado |
| `mpanel site-add loja --php 8.4` | Cria um site |
| `mpanel site-domains loja --set "loja.pt www.loja.pt" --ssl le` | Define domínios e pede certificado Let's Encrypt |
| `mpanel site-php loja 8.3` | Muda a versão de PHP |
| `mpanel site-disable loja` / `site-enable loja` | Desativa / ativa |
| `mpanel site-fixperms loja` | Corrige donos e permissões dos ficheiros |
| `mpanel site-ftp loja --password 'Segura123456'` | Ativa o FTP/SFTP do site (`--off` desativa) |
| `mpanel site-del loja --keep-files` | Apaga o site mantendo os ficheiros |
| `mpanel ext-add 8.4 imagick` | Instala uma extensão de PHP |
| `mpanel ngx-sync` | Regenera a configuração do nginx de todos os sites |
| `mpanel ssl-renew` | Renova os certificados que estejam perto de expirar |

### Bases de dados

| Comando | O que faz |
| --- | --- |
| `mpanel db-list` | Lista as bases de dados |
| `mpanel db-add loja_bd` | Cria uma base de dados (mostra a password) |
| `mpanel db-passwd loja_bd` | Muda a password do utilizador da base |
| `mpanel db-link loja_bd loja` | Associa a base a um site (entra nos backups dele) |
| `mpanel db-del loja_bd` | Apaga |

### Email

| Comando | O que faz |
| --- | --- |
| `mpanel mail-enable --host host.iddigital.pt` | Ativa o email ou muda o nome do servidor |
| `mpanel mail-domain-add pontoderede.pt` | Acrescenta um domínio |
| `mpanel mail-dns-info pontoderede.pt` · `mail-dns-check` | Mostra / verifica os registos DNS |
| `mpanel mail-box-add geral@pontoderede.pt` | Cria uma caixa |
| `mpanel mail-queue list` · `flush` | Mostra / tenta entregar a fila |
| `mpanel mail-site loja --resume` | Retoma o envio de um site suspenso |

### Segurança e ligações

| Comando | O que faz |
| --- | --- |
| `mpanel block 1.2.3.4 --for 24h` | Bloqueia um IP ou gama (`perm` = permanente) |
| `mpanel unblock 1.2.3.4` | Desbloqueia |
| `mpanel block-list` | Lista os bloqueios |
| `mpanel allow-add 89.155.10.20` | Acrescenta um IP de confiança |
| `mpanel geo-block add CN` · `del CN` | Bloqueia / desbloqueia um país |
| `mpanel fw-restore` | Recarrega a firewall do painel |
| `mpanel panel-allow none` | Retira a restrição de IPs do painel (se ficaste de fora) |
| `mpanel panel-2fa off` | Desliga o 2FA do painel (se perdeste o telemóvel) |
| `mpanel passwd` | Define uma password nova para o painel |
| `mpanel terminal-stop` | Fecha o Terminal aberto pelo painel |

### Desempenho

| Comando | O que faz |
| --- | --- |
| `mpanel site-perf loja --cache 600 --pm dynamic --redis on --redis-mem 128` | Cache de 10 min, processos sempre prontos, Redis de 128 MB |
| `mpanel cache-purge loja` | Limpa a cache de página do site |
| `mpanel site-webp loja` | Converte as imagens do site em WebP |
| `mpanel opcache-reset` | Limpa o OPcache |
| `mpanel db-tune --buffer auto --slow on --slow-time 2` | Afina o MariaDB (reinicia-o; repõe se falhar) |
| `mpanel brotli on` · `mpanel net-tune on` | Compressão Brotli · rede afinada (BBR) |

### Backups, atualizações e sistema

| Comando | O que faz |
| --- | --- |
| `mpanel backup-run` | Faz backup de tudo agora |
| `mpanel bk-list` · `bk-key` | Lista os backups / mostra a chave |
| `mpanel update-check` · `update-start` | Procura / instala a atualização do painel |
| `mpanel update-token set github_pat_…` | Guarda o token do GitHub (repositório privado) |
| `mpanel update-rollback` | Repõe a versão anterior do painel |
| `mpanel os-check` · `os-start --security` | Procura / instala atualizações do sistema |
| `mpanel service nginx restart` | Reinicia um serviço (nginx, mariadb, php-8.4, postfix, dovecot…) |
| `mpanel sentinel-run` | Corre todos os testes do Sentinela agora |
| `mpanel proc-kill 1234` · `proc-kill-site loja` | Termina um processo / todos os de um site |
| `mpanel alerts-test` | Envia um alerta de teste (SMS e email) |
| `mpanel state` | Volta a gerar o estado que o painel mostra |

## 13. Linux essencial

Com duas dúzias de comandos resolve-se quase tudo. Escreve o comando, lê-o, e só depois carrega em Enter.

### Truques da consola

- **Tab** completa nomes de ficheiros e comandos (escreve `/etc/mini` e carrega em Tab).
- **Seta para cima** repete os comandos anteriores.
- **Ctrl+C** interrompe o comando que está a correr (não é copiar!).
- **Ctrl+R** procura nos comandos anteriores.
- Copiar e colar no terminal do browser: Ctrl+Shift+C e Ctrl+Shift+V (ou o botão direito).
- `comando --help` ou `man comando` mostram a ajuda de qualquer comando (sai com `q`).

### Pastas e ficheiros

| Para | Comando |
| --- | --- |
| Ver em que pasta estás | `pwd` |
| Entrar numa pasta | `cd /srv/www/loja/public_html` |
| Voltar à pasta anterior / à pasta pessoal | `cd -` · `cd` |
| Listar ficheiros (com tamanhos e donos) | `ls -lah` |
| Ver um ficheiro | `cat ficheiro` · `less ficheiro` (sai com `q`) |
| Ver o fim de um ficheiro / seguir em direto | `tail -n 50 ficheiro` · `tail -f ficheiro` |
| Procurar texto num ficheiro | `grep -i "erro" ficheiro` |
| Procurar ficheiros pelo nome | `find /srv/www -name "wp-config.php"` |
| Copiar / mover ou mudar o nome | `cp origem destino` · `mv origem destino` |
| Criar uma pasta | `mkdir nova` |
| Apagar um ficheiro / uma pasta inteira | `rm ficheiro` · `rm -r pasta` |
| Comprimir / descomprimir | `tar czf arquivo.tar.gz pasta` · `tar xzf arquivo.tar.gz` |

`rm -r` não pede confirmação nem vai para o lixo. Confirma sempre o caminho antes (com `ls`).

### Editar ficheiros com o nano

`nano /caminho/ficheiro` abre o editor. Escreves normalmente; **Ctrl+O** e Enter grava; **Ctrl+X** sai; **Ctrl+W** procura. Antes de editar algo importante: `cp ficheiro ficheiro.bak`.

### Donos e permissões

No `ls -l`, cada ficheiro mostra permissões (ex.: `-rw-r-----`), dono e grupo (ex.: `mp_loja mp_loja`). Os ficheiros de cada site devem pertencer ao utilizador do site. Se copiaste ficheiros como root e o site dá erro de permissões: `mpanel site-fixperms loja`.

### Serviços (systemctl)

| Para | Comando |
| --- | --- |
| Ver o estado de um serviço | `systemctl status nginx` |
| Reiniciar / recarregar | `systemctl restart nginx` · `systemctl reload nginx` |
| Parar / arrancar | `systemctl stop nginx` · `systemctl start nginx` |
| Ver os serviços que falharam | `systemctl --failed` |

Nomes dos serviços: `nginx`, `mariadb`, `php8.4-fpm` (uma por versão), `postfix`, `dovecot`, `rspamd`, `redis-server`, `minipainel-redis@<site>`, `unbound`, `nsd`, `pure-ftpd`, `cron`, `ssh`, `minipainel-stats`. Antes de reiniciar o nginx, confirma a configuração com `nginx -t`.

### Registos do sistema (journalctl)

| Para | Comando |
| --- | --- |
| Últimas linhas de um serviço | `journalctl -u nginx -n 50` |
| Seguir em direto | `journalctl -u postfix -f` |
| Desde uma hora | `journalctl -u mariadb --since "1 hour ago"` |
| Mensagens do kernel (falta de memória, disco) | `journalctl -k -n 50` |
| Só erros desde hoje | `journalctl -p err --since today` |

### Disco, memória e carga

| Para | Comando |
| --- | --- |
| Espaço em disco | `df -h` |
| O que ocupa mais numa pasta | `du -sh /srv/www/* \| sort -h` |
| Memória | `free -h` |
| Processos e carga em tempo real | `htop` (ou `top`; sai com `q`) |
| Há quanto tempo está ligado e a carga | `uptime` |

A "carga" (load average) compara-se com o número de processadores: em 4 núcleos, carga 4 é o máximo confortável.

### Rede

| Para | Comando |
| --- | --- |
| IPs do servidor | `ip -br addr` |
| IP com que o servidor sai para a Internet | `curl -4 ifconfig.me` |
| Portas à escuta | `ss -tlnp` |
| Testar uma porta noutro servidor | `nc -vz gmail-smtp-in.l.google.com 25` |
| Testar um site a partir do servidor | `curl -I https://loja.pt` |
| Ligações ao servidor | Sistema → Ligações, ou `ss -tn` |

### Desligar e reiniciar

`reboot` reinicia o servidor (os sites ficam fora 1 a 2 minutos). Prefere o botão do painel (Atualizações → Sistema operativo), que pede confirmação.

## 14. Diagnóstico de problemas

Começa sempre pelo Sentinela (Sistema → Sentinela → Testar agora): na maioria dos casos aponta logo o serviço em falha. Se não chegar, segue a receita do sintoma.

### O site não abre

| O browser diz | Causa provável | O que fazer |
| --- | --- | --- |
| `DNS_PROBE_FINISHED_NXDOMAIN` / "não é possível encontrar" | O domínio não existe no DNS | `dig +short loja.pt @8.8.8.8` deve devolver o IP; cria o registo A |
| `ERR_HTTP2_PROTOCOL_ERROR` ou "ligação fechada" em HTTPS | O domínio não tem certificado | Sites → ⋮ → Domínios e SSL → Guardar (com o DNS já certo) |
| "Ligação recusada" / timeout | nginx parado, firewall ou porta fechada | `systemctl status nginx`; Ligações → o teu IP não está bloqueado? |
| 502 Bad Gateway | O PHP do site não respondeu | `systemctl status php8.4-fpm` (a versão do site) → `systemctl restart php8.4-fpm` |
| 504 Gateway Timeout | O PHP demorou demasiado | Logs → PHP lento e Erros do PHP; aumenta o tempo em Sites → ⋮ → Limites |
| 500 Internal Server Error | Erro no código do site | Logs → Erros do PHP (a última linha diz o ficheiro e a linha) |
| 403 Forbidden | Permissões ou falta de `index.php`/`index.html` | `mpanel site-fixperms loja`; confirma o ficheiro inicial |
| Redireciona para outro domínio | Configuração da própria aplicação | WordPress: `siteurl`/`home`; PrestaShop: `ps_shop_url` e `PS_SHOP_DOMAIN` |
| Mostra o site antigo / alterações não aparecem | Cache (DNS, página ou OPcache) | `dig +short loja.pt @8.8.8.8`; Limpar cache e Limpar OPcache; no Windows `ipconfig /flushdns` |

### O painel não abre

1. Entra por SSH ou pela consola do Proxmox.
2. `systemctl status nginx` e `systemctl status php8.4-fpm` (o PHP do painel é o 8.4).
3. `nginx -t` mostra erros de configuração; `journalctl -u nginx -n 30` mostra o motivo.
4. Ficaste de fora pelos IPs autorizados: `mpanel panel-allow none`.
5. O teu IP foi bloqueado: `mpanel block-list` e `mpanel unblock O-TEU-IP`.

### O email não chega ou não sai

1. Fila: `postqueue -p`. Mensagens presas mostram o motivo (ex.: "Connection timed out" = a porta 25 de saída está bloqueada no fornecedor).
2. O que aconteceu a uma mensagem: `journalctl -u postfix --since today | grep destinatario@exemplo.pt`.
3. Vai para o spam no Gmail/Outlook: confirma SPF, DKIM, DMARC e PTR (Email → ⋮ → Registos DNS → Verificar).
4. Não recebe: `dig +short MX dominio.pt` deve apontar para o servidor; de outro computador, `nc -vz host.iddigital.pt 25`.
5. Um site deixou de enviar: Email → Envio dos sites (pode ter sido suspenso por spam).
6. Um programa de email não entra: confirma servidor, porta 993/465 com SSL e utilizador = endereço completo; ao fim de 10 tentativas erradas o IP é bloqueado (Ligações → Bloqueios).

### O certificado não é emitido

- O DNS ainda não aponta para o servidor (`dig +short dominio @8.8.8.8`).
- Há um registo AAAA a apontar para outro sítio, ou um CAA que não inclui `letsencrypt.org`.
- As portas 80 e 443 não chegam ao servidor (firewall do fornecedor, NAT, país bloqueado).
- Muitas tentativas falhadas: o Let's Encrypt bloqueia temporariamente (espera 1 hora).
- Detalhe: `journalctl -t certbot -n 50` e `/var/log/letsencrypt/letsencrypt.log`.

### O servidor está lento

1. Sistema → Processos: quem consome CPU e memória (um site? a base de dados?).
2. Logs → Acessos → Páginas mais lentas; Logs → PHP lento (ficheiro e função).
3. Bases de dados → Consultas mais lentas.
4. `htop` na consola; `free -h` (pouca memória livre e swap a crescer = falta de RAM).
5. Logs → Acessos do site suspeito: muitos pedidos de um IP ou robô? Bloqueia em Ligações.
6. Liga a cache de página e o Redis do site (secção 16).

### O disco está cheio

1. `df -h` mostra qual a partição cheia.
2. `du -sh /srv/www/* /var/backups/minipainel/* /var/log /var/mail/vhosts/* 2>/dev/null | sort -h` mostra o que ocupa mais.
3. Culpados habituais: backups (reduz a retenção), caixas de email enormes, logs de debug de aplicações, `/tmp`.
4. Apaga ficheiros pelo painel (Ficheiros) ou com `rm`, sempre confirmando o caminho.

### Um serviço não arranca

`systemctl status <serviço>` e `journalctl -u <serviço> -n 50` dizem o motivo (normalmente um erro de configuração ou uma porta ocupada). `ss -tlnp | grep :80` mostra quem ocupa uma porta.

## 15. Emergências

Em quase todas as emergências o caminho é o mesmo: entrar pela consola do Proxmox (que funciona sempre, mesmo sem rede nem painel) e usar o `mpanel`.

| Situação | Solução |
| --- | --- |
| Esqueci a password do painel | `mpanel passwd` (define uma nova) |
| Perdi o telemóvel do 2FA | Usa um dos 8 códigos de recuperação no login; sem eles: `mpanel panel-2fa off` e volta a ativar |
| Esqueci o nome de utilizador | `jq -r .user /var/lib/minipainel/auth.json` |
| Fiquei de fora pelos IPs autorizados | `mpanel panel-allow none` |
| O meu IP foi bloqueado | `mpanel block-list` → `mpanel unblock O-TEU-IP`; depois põe-no em IPs de confiança: `mpanel allow-add O-TEU-IP` |
| Um país foi bloqueado por engano | `mpanel geo-block del XX` |
| A firewall está a bloquear tudo | `nft delete table inet minipainel` (desliga a firewall do painel); `mpanel fw-restore` volta a ligá-la |
| Uma atualização partiu o painel | `mpanel update-rollback` (repõe a última cópia) |
| O terminal do painel fica em "A iniciar" | Espera 15 segundos (volta sozinho ao botão Abrir) ou `mpanel terminal-stop` |
| O servidor não arranca depois de um reinício | Consola do Proxmox: lê as mensagens no ecrã; se pedir verificação do disco, segue as instruções (normalmente `fsck` e Enter) |
| O site foi atacado (ficheiros alterados) | Desativa o site (`mpanel site-disable loja`), restaura o backup anterior ao ataque, muda as passwords do site e da base de dados, atualiza a aplicação |
| Um site está a enviar spam | Email → Envio dos sites → Suspender (ou `mpanel mail-site loja --suspend`); limpa a fila; procura o ficheiro responsável nos logs |
| Perdi o servidor inteiro | Instala um servidor novo, repõe a `backup.key` em `/etc/minipainel/`, configura o mesmo destino remoto e restaura os backups |

### Kit de emergência: guarda fora do servidor

- [ ] Utilizador e password do painel
- [ ] Os 8 códigos de recuperação do 2FA
- [ ] A chave dos backups (`mpanel bk-key`)
- [ ] Os dados de acesso ao destino remoto dos backups
- [ ] A password de root do servidor e o acesso à consola do Proxmox
- [ ] O token do GitHub (e, se usares assinatura, a chave privada de assinatura, com cópia offline)
- [ ] O token da bulksms.com

### Antes de mexer em algo sério

1. Faz um backup (`mpanel backup-run`).
2. Copia o ficheiro que vais mudar (`cp ficheiro ficheiro.bak`).
3. Muda uma coisa de cada vez e testa.
4. Se piorar, repõe a cópia (`cp ficheiro.bak ficheiro`) e reinicia o serviço.

## 16. Desempenho dos sites

O painel tem várias camadas de aceleração, quase todas por site em **Sites → ⋮ → Desempenho**. Para saber onde está a lentidão antes de mexer, usa a medição (Logs → Acessos e PHP lento; Bases de dados → Consultas mais lentas).

| Camada | O que faz | Onde se liga |
| --- | --- | --- |
| Cache de página | Guarda as páginas e serve-as sem executar o PHP (de 200–800 ms para 5–20 ms). Nunca guarda sessões iniciadas, carrinhos, checkout, áreas de cliente ou de administração, formulários nem páginas com sessão PHP | Desempenho → Cache de página; botão Limpar cache |
| Redis por site | Cache de objetos em memória para WordPress, WooCommerce, PrestaShop… Cada site tem o seu, acessível só por ele | Desempenho → Redis |
| Processos PHP | "Sempre prontos" elimina o atraso da primeira visita depois de uma pausa; máximo de processos em simultâneo | Desempenho → Processos PHP |
| OPcache | Código PHP compilado em memória, em todas as versões | Página PHP → OPcache; botão Limpar OPcache |
| MariaDB afinado | Memória para dados ajustada à RAM (por omissão o MariaDB usa só 128 MB) | Bases de dados → Desempenho do MariaDB |
| Cache no browser | Imagens, CSS, JS e fontes não são descarregados outra vez por quem regressa (7, 30 ou 365 dias) | Desempenho → Ficheiros estáticos |
| WebP | Entrega `imagem.jpg.webp` (25–75% mais leve) a quem o suporta; converte as imagens do site a pedido ou todas as noites | Desempenho → WebP; botão Converter imagens |
| Brotli | HTML, CSS e JS mais pequenos do que com gzip | Definições → Serviços → Rede e compressão |
| Rede (TCP BBR) | Mais rápido para visitantes em redes móveis ou distantes | Definições → Serviços → Rede e compressão |

Nota: o PrestaShop e o OpenCart criam um cookie para todos os visitantes, por isso a cache de página quase nunca se aplica a essas lojas (é o comportamento seguro). Nelas, o ganho grande vem do Redis, do OPcache e do MariaDB afinado.

### Redis no WordPress

Instala o plugin "Redis Object Cache" e acrescenta ao `wp-config.php` (o caminho exato aparece no painel, em Desempenho):

```
define('WP_REDIS_SCHEME', 'unix');
define('WP_REDIS_PATH', '/srv/www/loja/tmp/redis.sock');
```

Depois, no WordPress: Definições → Redis → Enable Object Cache.

### Confirmar que a cache funciona

`curl -sI https://loja.pt | grep -i x-cache`: `HIT` = servido da cache; `MISS` = gerado agora (o seguinte será HIT); `BYPASS` = propositadamente fora da cache (sessão, carrinho…). Em Logs → Acessos aparece a percentagem servida pela cache.

### Depois de alterar ficheiros de um site

Se as alterações não aparecem de imediato: **Limpar OPcache** (página PHP) e **Limpar cache** (Desempenho do site).

## 17. Glossário

| Termo | Significado |
| --- | --- |
| 2FA | Verificação em dois passos: password mais um código do telemóvel |
| A / AAAA | Registos DNS que ligam um nome a um IP (IPv4 / IPv6) |
| Backup | Cópia de segurança dos ficheiros, bases de dados e configuração |
| Brotli | Compressão mais eficiente do que o gzip, usada pelos browsers modernos |
| CAA | Registo DNS que diz que entidades podem emitir certificados para o domínio |
| Cache | Cópia guardada de algo já calculado, para responder mais depressa da vez seguinte |
| Certificado SSL/TLS | O que permite o `https://` e o cadeado no browser |
| CNAME | Registo DNS que aponta um nome para outro nome |
| Cron | Tarefas que correm sozinhas a horas certas |
| DKIM | Assinatura digital do email, que prova que vem do domínio |
| DMARC | Regra que diz aos outros servidores o que fazer ao email que falhe o SPF/DKIM |
| DNS | O sistema que traduz nomes (loja.pt) em IPs |
| DNSBL | Lista negra de IPs conhecidos por enviar spam |
| Firewall | Filtro que decide que ligações entram no servidor |
| FTPS / SFTP | Formas cifradas de transferir ficheiros (FTP com TLS / através do SSH) |
| Glue record | Registo A dos nameservers, criado na zona do domínio onde esses nomes vivem |
| IMAP / POP3 | Protocolos para ler o email (IMAP mantém no servidor; POP3 descarrega) |
| IP | Endereço numérico de um computador na Internet (ex.: 91.209.16.24) |
| Journal | Registo central de mensagens do Linux (`journalctl`) |
| Let's Encrypt | Entidade que emite certificados SSL gratuitos |
| LAN | Rede local (escritório, casa) |
| MX | Registo DNS que indica o servidor de email de um domínio |
| NAT | Router que partilha um IP público por vários computadores internos |
| Nameserver | Servidor que responde pelo DNS de um domínio |
| nftables | A firewall do Linux usada pelo painel |
| OPcache | Memória onde o PHP guarda o código já compilado |
| Pool PHP | Conjunto de processos PHP de um site, com o utilizador desse site |
| Porta | Número que identifica um serviço num IP (80 HTTP, 443 HTTPS, 22 SSH, 25 email) |
| PTR | DNS inverso: liga um IP a um nome; essencial para o email não ir para o spam |
| Redis | Base de dados em memória, usada como cache |
| root | Administrador do Linux, com todas as permissões |
| Serviço | Programa que corre sempre em segundo plano |
| SMTP | Protocolo de envio de email |
| SPF | Registo DNS que diz que servidores podem enviar email pelo domínio |
| SSH | Acesso remoto cifrado à consola do servidor |
| Swap | Disco usado como memória extra quando a RAM acaba (lento) |
| TTL | Tempo, em segundos, que os outros servidores guardam um registo DNS em cache |
| WebP | Formato de imagem mais leve do que JPEG e PNG |
| Zona DNS | Conjunto de todos os registos DNS de um domínio |
