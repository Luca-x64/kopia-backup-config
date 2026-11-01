# Kopia Auto Backup

Script per Linux/systemd che controlla periodicamente la disponibilità
del repository Kopia e avvia automaticamente gli snapshot delle sorgenti
configurate.

## Comportamento

-   Il timer controlla il backup ogni `CHECK_INTERVAL` (predefinito:
    `15min`).
-   Crea uno snapshot quando il repository è raggiungibile e per quella
    sorgente è trascorso almeno `MIN_INTERVAL_DAYS` (predefinito: 7
    giorni) dall'ultimo snapshot completato.
-   Al primo avvio, salva le sorgenti senza uno snapshot precedente.
-   Se il repository non è raggiungibile, non avvia snapshot e riprova
    al controllo successivo.
-   Valuta ogni sorgente separatamente. Salta quelle inesistenti e prova
    le altre anche se una sorgente restituisce un errore.
-   Considera anche gli snapshot già presenti nel repository per
    l'utente e l'host configurati.

Il progetto crea snapshot Kopia: **non è una sincronizzazione
bidirezionale** e non elimina i dati dal PC. La conservazione e la
deduplicazione sono gestite da Kopia e dalle policy del repository.

## Configurazione

Modificare `.env` prima dell'installazione. `.env.example` è il modello
da copiare per configurare una nuova macchina. Il file contiene:

-   `KOPIA_PATH`: percorso dell'eseguibile Kopia.
-   `KOPIA_USERNAME` e `KOPIA_HOSTNAME`: identità usate per riconoscere
    gli snapshot del client nel repository.
-   `SOURCES`: percorsi delle directory da salvare, separati da `|`.
    Non usare `|` nei nomi dei percorsi.
-   `MIN_INTERVAL_DAYS`: giorni minimi tra gli snapshot di una sorgente.
-   `REPOSITORY_TIMEOUT_SECONDS` e `LIST_TIMEOUT_SECONDS`: timeout per
    le operazioni Kopia.
-   `CHECK_INTERVAL`: frequenza dei controlli systemd, ad esempio
    `15min`, `1h` o `1d`.

L'installer copia `.env` con permessi utente (`600`) in
`~/.config/kopia-auto-backup/.env`. Non pubblicare il file: può contenere
percorsi e dettagli della configurazione locale.

Per una nuova macchina, copiare `.env.example` in `.env` e adattare i
percorsi. Il timer usa `CHECK_INTERVAL` (predefinito: 15min).

## Installazione

``` bash
chmod +x install-kopia-auto-backup.sh
./install-kopia-auto-backup.sh
```

Se `.env` non esiste ancora, crearlo dal modello prima di installare:

``` bash
cp .env.example .env
```

L'installer crea lo script in `~/.local/bin/`, copia la configurazione in
`~/.config/kopia-auto-backup/.env` e crea le unità systemd utente in
`~/.config/systemd/user/`, quindi abilita e avvia il timer.

## Requisiti

-   Linux con systemd e sessione utente attiva (oppure lingering
    abilitato per l'utente).
-   Python 3.
-   Kopia CLI installato nel percorso indicato da `KOPIA_PATH` in `.env`.
-   Client Kopia già collegato al repository remoto; `kopia repository
    status` deve riuscire.
-   Repository/NAS raggiungibile durante un controllo.

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

