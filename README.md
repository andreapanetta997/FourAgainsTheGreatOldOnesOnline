# Quattro contro i Grandi Antichi · Tavolo online

Tavolo condiviso per giocare a *Four Against the Great Old Ones* con un Narratore e fino a 4 giocatori, ognuno sul proprio dispositivo e senza account.

- **Narratore**: crea la partita, sceglie gli investigatori e riceve un codice per ogni giocatore. Vede e gestisce tutto: schede, giorni, viaggi, nemici, helper, indizi.
- **Giocatori**: inseriscono il codice (oppure aprono il link `?codice=XXXXXX`) e vedono **solo la propria scheda**.
- Tiri di dado, diario, giorno e luogo sono condivisi in tempo reale.

Il libro resta al Narratore: la pagina non contiene i testi di incontri e tabelle.

## Dati dei luoghi

Le meccaniche (indagini con caselle e ritiri, reclute, armi, combattimento guidato) sono nella pagina; i dati specifici di ogni luogo li inserisce il Narratore dal proprio libro la prima volta che il gruppo ci arriva (scheda **Luogo → Configura**). Restano salvati nel database, visibili solo con il codice Narratore, e valgono per tutte le partite successive.

## Come funziona

- `index.html`: pagina statica servita da GitHub Pages.
- Backend: Supabase. Le tabelle hanno RLS attivo senza policy, quindi non sono leggibili direttamente; tutto passa da funzioni `SECURITY DEFINER` che richiedono il codice Narratore (salvato solo come hash) o il codice del personaggio. Lo schema è in `supabase/schema.sql`.
- Sincronizzazione: dopo ogni modifica la pagina invia un segnale vuoto sul canale Realtime della partita e gli altri dispositivi ricaricano i dati tramite le funzioni. Nessun dato viaggia sul canale.

## Note

- Il progetto Supabase gratuito va in pausa dopo 7 giorni senza attività: prima di giocare, se serve, riattivalo dalla dashboard.
- La chiave nel file è quella pubblica (anon), pensata per stare nel browser.
