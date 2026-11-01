# Kopia Auto Backup

Script per Linux/systemd che controlla periodicamente la disponibilità
del repository Kopia e avvia automaticamente gli snapshot delle sorgenti
configurate.

Il backup parte quando il PC è acceso, il NAS è raggiungibile e sono
trascorsi almeno **7 giorni** dall'ultimo backup completato per quella
sorgente. Non accende né spegne i dispositivi.

## Requisiti

-   Linux con systemd.
-   Python 3.
-   Kopia CLI installato nel percorso indicato da `KOPIA_PATH` in `.env`.
-   Client Kopia già collegato al repository remoto
    (`kopia repository status` deve riuscire).
-   NAS acceso e Kopia Server raggiungibile al momento del controllo.

Il timer è un timer systemd utente: normalmente funziona mentre la
sessione dell'utente è attiva.

## Configurazione

Modificare `.env` prima dell'installazione. Contiene percorso e identità
Kopia, sorgenti, intervallo minimo tra snapshot, timeout e frequenza del
timer. `SOURCES` è una lista di percorsi separati da `|`; non usare `|`
nei nomi dei percorsi. Il file viene installato con permessi utente
(`600`) in `~/.config/kopia-auto-backup/.env` e non va pubblicato.

Per una nuova macchina, copiare `.env.example` in `.env` e adattare i
percorsi. Il timer usa `CHECK_INTERVAL` (predefinito: 15min).

## Installazione

``` bash
chmod +x install-kopia-auto-backup.sh
./install-kopia-auto-backup.sh
```

L'installer crea lo script in `~/.local/bin/`, copia la configurazione in
`~/.config/kopia-auto-backup/.env` e crea le unità systemd utente in
`~/.config/systemd/user/`, quindi abilita e avvia il timer.

## Comandi utili

Avviare subito un controllo:

``` bash
systemctl --user start kopia-auto-backup.service
```

Verificare il timer:

``` bash
systemctl --user list-timers kopia-auto-backup.timer
```

Consultare i log:

``` bash
journalctl --user -u kopia-auto-backup.service
```

Seguire i log in tempo reale:

``` bash
journalctl --user -u kopia-auto-backup.service -f
```

Disabilitare il controllo automatico:

``` bash
systemctl --user disable --now kopia-auto-backup.timer
```

Riabilitarlo:

``` bash
systemctl --user enable --now kopia-auto-backup.timer
```

## Comportamento

-   Il controllo viene eseguito ogni `CHECK_INTERVAL` (predefinito:
    15 minuti).
-   Se il repository non è raggiungibile, il controllo termina senza
    avviare snapshot; riprova al controllo successivo.
-   Ogni sorgente viene valutata separatamente.
-   Al primo avvio, le sorgenti senza uno snapshot precedente vengono
    salvate appena il repository è disponibile.
-   Se una sorgente non esiste, viene saltata.
-   Un errore su una sorgente non impedisce di tentare il backup delle
    altre.
-   L'intervallo minimo viene calcolato dall'ultimo snapshot completato,
    includendo quelli già presenti nella cronologia del repository per
    l'utente e l'host configurati.

Il progetto crea snapshot Kopia: **non è una sincronizzazione
bidirezionale** e non elimina i dati dal PC. La conservazione e la
deduplicazione sono gestite da Kopia e dalle policy del repository.
