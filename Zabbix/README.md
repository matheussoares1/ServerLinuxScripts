# Backup automatizado do banco de dados Zabbix via SMB/CIFS

Guia para realizar backups diários do banco **Zabbix** (MariaDB) em um compartilhamento de rede SMB, com compactação, verificação de integridade, logs e retenção automática.

## Ambiente de referência

| Item | Configuração |
|---|---|
| Sistema | Ubuntu Server 24.04 |
| Monitoramento | Zabbix 7.4 |
| Banco | MariaDB 10.11 |
| Banco de dados | `zabbix` |
| Servidor de arquivos | `192.168.0.151` |
| Caminho Windows | `\\192.168.0.151\Backups\Zabbix` |
| Compartilhamento SMB | `//192.168.0.151/Backups` |
| Subpasta | `Zabbix` |
| Ponto de montagem Linux | `/mnt/backup-zabbix` |
| Diretório final | `/mnt/backup-zabbix/Zabbix` |
| Retenção | 7 dias (ajustável) |
| Agendamento | 02:00 diariamente (horário do servidor) |

> **Atenção:** pressupõe que `Backups` seja o nome do compartilhamento SMB e `Zabbix` uma subpasta. Se a organização do compartilhamento for diferente, ajuste os caminhos. Execute os comandos como usuário com `sudo`. Não publique credenciais no GitHub.

## 1. Conferir o MariaDB

```bash
sudo systemctl status mariadb
sudo systemctl start mariadb    # somente se estiver parado
sudo systemctl enable mariadb   # habilita no boot; não inicia o serviço
sudo mariadb -e 'SHOW DATABASES;'
```

Confirme que o banco `zabbix` existe. O script usa a autenticação local do MariaDB como `root` via socket (execução pelo `root` do Linux); valide antes com `sudo mariadb -e 'SELECT 1;'`.

## 2. Instalar os pacotes SMB/CIFS

```bash
sudo apt update
sudo apt install -y cifs-utils smbclient
```

Crie o ponto de montagem:

```bash
sudo mkdir -p /mnt/backup-zabbix
```

## 3. Configurar credenciais SMB

Crie um arquivo **fora do repositório Git**:

```bash
sudo nano /root/.smb-zabbix
```

Insira, substituindo pelos dados reais:

```ini
username=USUARIO_DO_COMPARTILHAMENTO
password=SENHA_DO_COMPARTILHAMENTO
# domain=DOMINIO_OU_COMPUTADOR  # se necessário
```

Proteja o arquivo:

```bash
sudo chown root:root /root/.smb-zabbix
sudo chmod 600 /root/.smb-zabbix
```

A conta SMB precisa ter permissão de escrita e exclusão na pasta `Zabbix` para que a retenção funcione.

## 4. Testar a montagem SMB

```bash
sudo mount -t cifs //192.168.0.151/Backups /mnt/backup-zabbix \
  -o credentials=/root/.smb-zabbix,vers=3.0,iocharset=utf8
```

Verifique a montagem:

```bash
findmnt /mnt/backup-zabbix
ls -la /mnt/backup-zabbix
```

Se a subpasta ainda não existir e a conta tiver permissão:

```bash
sudo mkdir -p /mnt/backup-zabbix/Zabbix
```

Teste a escrita sem deixar arquivo de teste:

```bash
sudo touch /mnt/backup-zabbix/Zabbix/.teste-escrita
sudo rm /mnt/backup-zabbix/Zabbix/.teste-escrita
```

Se houver erro de montagem, verifique conectividade, credenciais, permissões e a versão SMB aceita pelo servidor. Não habilite SMBv1 como solução padrão.

## 5. Configurar montagem persistente

Depois de validar a montagem manual, edite:

```bash
sudo nano /etc/fstab
```

Adicione **uma única linha**:

```fstab
//192.168.0.151/Backups /mnt/backup-zabbix cifs credentials=/root/.smb-zabbix,vers=3.0,iocharset=utf8,_netdev,nofail,x-systemd.automount 0 0
```

Recarregue e teste:

```bash
sudo systemctl daemon-reload
sudo mount -a
ls /mnt/backup-zabbix/Zabbix
findmnt -T /mnt/backup-zabbix/Zabbix
```

Com `x-systemd.automount`, o acesso ao diretório pode disparar a montagem sob demanda. `nofail` evita que a indisponibilidade do compartilhamento bloqueie o boot.

## 6. Instalar o script de backup

Salve o arquivo [`backup-zabbix-smb.sh`](backup-zabbix-smb.sh) deste repositório em `/usr/local/sbin/backup-zabbix.sh`:

```bash
sudo install -o root -g root -m 700 backup-zabbix-smb.sh /usr/local/sbin/backup-zabbix.sh
```

O script realiza:

1. Verificação da montagem SMB e das permissões de escrita.
2. Verificação da disponibilidade do MariaDB.
3. Exportação do banco com `mariadb-dump --single-transaction --quick`.
4. Compactação para `.sql.gz` e validação com `gzip -t`.
5. Renomeação do arquivo temporário após a conclusão.
6. Exclusão de backups antigos conforme a retenção configurada.
7. Registro em `/var/log/zabbix-db-backup.log`.

> O `--single-transaction` fornece uma exportação consistente para tabelas transacionais, como InnoDB, desde que não haja alterações concorrentes de estrutura (DDL). Ele não substitui snapshots nem garante consistência transacional de tabelas não transacionais.

### Conteúdo do script

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DB_NAME="zabbix"
MOUNT="/mnt/backup-zabbix"
DEST="$MOUNT/Zabbix"
RETENTION_DAYS=7
STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
LOG="/var/log/zabbix-db-backup.log"
FILE="$DEST/zabbix_${STAMP}.sql.gz"
TMP="$FILE.part"

exec >>"$LOG" 2>&1
trap 'rc=$?; rm -f -- "$TMP"; echo "$(date -Is) ERROR: backup failed (exit $rc)"; exit "$rc"' ERR

echo "$(date -Is) Starting backup"
if ! mountpoint -q "$MOUNT"; then
  echo "SMB share is not mounted at $MOUNT; refusing local backup" >&2
  exit 1
fi
if [[ ! -d "$DEST" || ! -w "$DEST" ]]; then
  echo "Backup destination unavailable or not writable: $DEST" >&2
  exit 1
fi

mariadb-admin ping --silent >/dev/null
mariadb-dump --single-transaction --quick --routines --events --triggers --hex-blob --databases "$DB_NAME" | gzip -c > "$TMP"
test -s "$TMP"
gzip -t "$TMP"
mv -n -- "$TMP" "$FILE"
find "$DEST" -maxdepth 1 -type f -name 'zabbix_*.sql.gz' -mtime +"$RETENTION_DAYS" -delete

echo "$(date -Is) Backup complete: $FILE ($(du -h "$FILE" | cut -f1))"
trap - ERR
```

> O script completo deve ficar em arquivo separado, com permissão `700`. O `set -o pipefail` faz a execução falhar se o dump falhar, mesmo quando o `gzip` terminar normalmente. A limpeza por `-mtime +7` é baseada em períodos completos de 24 horas e pode manter arquivos por mais de sete dias de calendário.

## 7. Executar manualmente

```bash
sudo /usr/local/sbin/backup-zabbix.sh
```

Conferir os arquivos e o log:

```bash
sudo ls -lh /mnt/backup-zabbix/Zabbix/
sudo tail -n 50 /var/log/zabbix-db-backup.log
```

Testar todos os arquivos compactados:

```bash
sudo find /mnt/backup-zabbix/Zabbix -maxdepth 1 -name 'zabbix_*.sql.gz' \
  -type f -exec gzip -t {} \;
```

## 8. Agendar backup diário

Edite o crontab do `root`:

```bash
sudo crontab -e
```

Adicione:

```cron
0 2 * * * /usr/local/sbin/backup-zabbix.sh
```

Verifique:

```bash
sudo crontab -l
```

**Horário:** 02:00 no fuso horário configurado no Ubuntu. Confira com `timedatectl`.

## 9. Diagnóstico de problemas

**Erro `Database error – No such file or directory`:**

```bash
sudo systemctl status mariadb
sudo journalctl -u mariadb -n 100 --no-pager
```

**Compartilhamento indisponível:**

```bash
findmnt -T /mnt/backup-zabbix/Zabbix
sudo journalctl -k -n 100 --no-pager | grep -i cifs
```

**Permissões SMB:** confira a conta no arquivo `/root/.smb-zabbix`, permissões no compartilhamento e na pasta `Zabbix`, e teste `touch`/`rm` novamente.

**Falta de espaço:**

```bash
df -h /mnt/backup-zabbix/Zabbix
```

**Logs do backup:**

```bash
sudo tail -n 100 /var/log/zabbix-db-backup.log
```

## 10. Restauração — somente em ambiente de teste primeiro

**Nunca restaure diretamente em produção sem plano de recuperação e janela de manutenção.** A restauração pode sobrescrever dados existentes. Copie o backup para um ambiente isolado, valide sua integridade e confirme que a versão/esquema são compatíveis.

Exemplo para **banco de testes** já criado e com permissões adequadas (ajuste o caminho):

```bash
sudo mariadb -e 'CREATE DATABASE IF NOT EXISTS zabbix_restore_test CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;'
# O dump foi gerado com --databases zabbix, incluindo USE zabbix.
# Portanto, NÃO importe diretamente esse dump no banco de testes:
# ele selecionaria o banco original. Faça uma restauração em instância
# MariaDB isolada ou prepare uma cópia adaptada e revisada do dump.
```

O teste de `gzip -t` verifica a integridade do arquivo compactado, mas **não comprova que o banco pode ser restaurado**. Faça ensaios de restauração periódicos em uma instância isolada.

## 11. Recomendações de segurança e operação

- Mantenha o arquivo de credenciais apenas no servidor, com permissão `600`.
- Use uma conta SMB exclusiva para backup, com o mínimo de permissões necessário.
- Restrinja acesso ao diretório e aos logs, pois o banco pode conter dados sensíveis.
- Garanta espaço livre suficiente e monitore falhas do cron.
- Mantenha cópia adicional offline ou imutável: backups em SMB podem ser apagados por erro humano ou comprometimento da conta.
- Faça backups também dos arquivos de configuração do Zabbix e de eventuais scripts externos; o dump do banco sozinho não cobre toda a instalação.
- Teste a restauração regularmente e documente o procedimento de recuperação.

## Licença e uso

Adapte este guia à sua infraestrutura. Nunca versione senhas, dumps reais ou dados pessoais em repositórios públicos.
