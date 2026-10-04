# IDDigital Hosting (MiniPainel)

Painel de alojamento leve para servidores Linux (Debian, Ubuntu, AlmaLinux, Rocky): sites com PHP 7.0–8.5, MariaDB, email completo, DNS autoritativo, backups, firewall, Sentinela e alertas.

## Instalar ou atualizar

```bash
wget -O /tmp/install.sh https://raw.githubusercontent.com/naoavr/painel-alojamento-nao/main/install.sh && bash /tmp/install.sh
```

Com o repositório privado, acrescenta `--header="Authorization: Bearer <token só de leitura>"` ao `wget`. Depois de instalado, as atualizações fazem-se no painel (Sistema → Atualizações).

## Estrutura

| Caminho | Conteúdo |
| --- | --- |
| `install.sh` | **Gerado** por `build.sh` — é o que os servidores descarregam. Não editar à mão. |
| `build.sh` | Junta `src/` num único `install.sh` |
| `src/installer.sh` | Instalação (pacotes, nginx, PHP, MariaDB…); as linhas `@@INCLUDE …@@` indicam onde entra cada ficheiro |
| `src/cli/` | Comando `mpanel`, dividido por área (sites, email, DNS, backups, Sentinela…) |
| `src/panel/` | Painel web (`index.php`), API do gestor de ficheiros, gerador de QR |
| `src/stats/` | Recolhedor de estatísticas (`mpanel-stats`) |
| `src/helpers/` | `mpanel-cron`, `mp-sendmail`, `mpanel-term`, construtor da base de países |
| `docs/manual.md` | Manual do utilizador (também incluído no painel, botão Manual) |
| `CHANGELOG.md` | O que mudou em cada versão |

## Publicar uma versão

1. Alterar os ficheiros em `src/` (e a versão em `MP_VERSION` e na linha `# NOTAS:` de `src/installer.sh`).
2. `bash build.sh` — gera o `install.sh`.
3. Commit e push. O CI confirma que o `install.sh` corresponde a `src/` e verifica a sintaxe (bash, PHP, ShellCheck).
4. No painel: Sistema → Atualizações → Procurar atualizações → Atualizar.
