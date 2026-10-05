# Registo de alterações

## 2.14.1
- Ficheiros: copiar e mover entre sites (barra de seleção e menu de cada item), com escolha do site e da pasta de destino e do que fazer com nomes repetidos; dono e permissões do site de destino; atalhos não copiados; mover só apaga a origem depois da cópia.
- Domínio do painel: ao mudar para outro nome, página de espera que encaminha para o endereço novo (e indica o endereço de recurso por IP).
- DNS: coluna TTL sem partir o "Auto"; "Verificar agora" só testa os nameservers deste servidor que estão em uso.

## 2.14.0
- DNS secundário externo (Servidor DNS): Hurricane Electric pré-configurada ou outro serviço. Cópia das zonas autorizada só aos servidores do serviço, protegida com chave TSIG; aviso (NOTIFY) a cada alteração, sempre a partir do IP público; os nameservers do serviço entram nos registos NS de todas as zonas.
- O painel mostra os dados exatos a preencher no serviço ("Add a new slave") e os nameservers a pôr no registador; "Verificar agora" confirma, zona a zona, que a cópia está em dia.
- Resolve a regra do DNS.PT de nameservers com IPs diferentes sem segundo IP nem segundo servidor.

## 2.13.4
- Alertas: "Enviar mensagem de teste" no cartão Email (sai o cartão solto).
- Backups → Agendamento e destinos: os dois a toda a largura.
- Atualizações: Painel a toda a largura e Repositório | Chave com a mesma altura; a faixa de erro antiga só aparece se a versão instalada for anterior à que falhou.
- Resumo: Serviços compacto ("todos a correr" ou só os que têm problemas).
- Definições: "Logs dos sites" passa para o separador Serviços.

## 2.13.3
- Logs: indicadores e as 4 listas numa linha (alturas iguais); acessos com 50 por página; datas e IPs sem cortes.
- Auditoria: filtros (texto, utilizador, resultado) aplicados ao registo todo — antes só à página visível; colunas fixas; 50 por página.

## 2.13.2
- Bases de dados: separadores Bases de dados · Desempenho · phpMyAdmin (abre na lista).
- PHP: separadores Versões · Extensões · OPcache (escolher uma versão abre as extensões dela).

## 2.13.1
- Interface: cabeçalho em dois níveis em todas as páginas — ferramentas globais em cima; título, descrição e ação principal da página por baixo (o título deixa de ficar espremido).
- Telemóvel: ferramentas do topo numa só linha; o separador ativo deixava de ficar espremido num círculo.

## 2.13.0
- DNS refeito como no Cloudflare: editar registos (também os do painel), modelos de email (este servidor, Google Workspace, Microsoft 365), importar e exportar zonas BIND, verificar propagação, repor predefinidos, TTL "Auto".
- Separador Servidor DNS: estado, verificação de saúde (nameservers na Internet, UDP/TCP, transferência de zona, resolver aberto), nameservers e valores do SOA.
- Correção: o gerador de zonas deslocava colunas com TTL automático (as zonas eram recusadas, nunca ativadas).

## 2.12.4
- Remove as zonas DNS falsas (bin, boot, dev…) criadas por um erro antigo; a sincronização nunca cria zonas. Página DNS mais clara.

## 2.12.3
- Sentinela: resumo "O que precisa de atenção" e separadores por grupo. Correções: zonas fantasma no Sentinela, teste dos backups.
- Layout: tabelas sem texto fora dos cartões em todas as páginas (verificado a 1440, 1280 e 1100 px).

## 2.12.2
- Manual do utilizador dentro do painel (índice, pesquisa, descarregar .md).

## 2.12.1
- Páginas de Sistema passam para o menu "Sistema" no canto superior direito.

## 2.12.0
- Redis por site (isolado), cache no browser, WebP automático e conversão, Brotli, TCP BBR.

## 2.11.2
- Correção: tarefas do cron sem `PATH` completo (Sentinela e IPs de confiança não encontravam `nft`); terminal preso em "A iniciar".

## 2.11.1
- Atualizações a partir de repositório privado (token só de leitura); `version.json` e assinatura opcionais.

## 2.11.0
- Cache de página (FastCGI), processos PHP "sempre prontos", OPcache, MariaDB afinado, consultas lentas, páginas e scripts PHP lentos.

## 2.10.0
- Sentinela: testa todos os serviços a cada minuto, repara e alerta.

## 2.9.0 e anteriores
- Processos, alertas por SMS/email, países e limite de ligações, terminal no browser, DNS autoritativo, logs, proteção contra força bruta, PHP 7.0–8.5, FTP/SFTP, email completo, backups, painel e CLI.
