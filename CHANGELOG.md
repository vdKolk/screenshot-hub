# Wijzigingen

Het versienummer staat in `VERSION`. Het buildnummer is het aantal commits; samen met de commit en de builddatum zie je het in **Screenshot Hub › Over Screenshot Hub**.

## 1.2.0

Gegevensbescherming:

- Opgeslagen screenshots en kopieën krijgen rechten 0600 (alleen de eigenaar); ook tijdelijke bestanden zijn alleen voor de eigenaar.
- Weggegooide of opgeslagen screenshots verdwijnen uit het geheugen zodra Ongedaan maken verloopt (na 6 seconden), in plaats van bewaard te blijven tot de volgende actie.
- Een tijdelijk opnamebestand dat na een crash achterbleef, wordt bij de volgende start opgeruimd.

Bestandsafhandeling:

- Opslaan, kopiëren en verplaatsen gaan via een tijdelijk bestand in dezelfde map en een hernoeming die nooit overschrijft (`renamex_np` met `RENAME_EXCL`). Een onderbroken opslag laat geen half bestand achter.
- Gesleepte bestanden moeten echt een afbeelding zijn (ImageIO controleert de inhoud), niet alleen de juiste extensie hebben.
- Namen van gesleepte bestanden worden opgeschoond: geen pad- of stuurtekens, niet verborgen, maximaal 200 bytes.

Foutafhandeling:

- Foutmeldingen zijn begrijpelijk en bevatten geen bestandsnamen of paden.
- Meldingen bij een mislukte schermopname, een onleesbaar bestand en een Hot Space waarvan de toegang is ingetrokken.
- Ongedaan maken dat niet lukt, zegt nu ook waarom.

Build:

- `bash build.sh --release` voor builds om te delen: weigert zonder Developer ID, zonder notarisatie of met niet-gecommitte wijzigingen.
- De dirty-markering kijkt alleen nog naar de bestanden waaruit de app wordt gebouwd, inclusief bestanden die nog niet in git staan.
- Swift-toolchain en macOS SDK staan in Info.plist en in het Over-venster.

## 1.1.0

Beveiliging:

- App Sandbox aan: de app kan alleen bij mappen die je zelf kiest en bij bestanden die je naar de app sleept. Geen netwerktoegang.
- Screenshotmap en Hot Spaces worden onthouden met security-scoped bookmarks.
- Hardened Runtime aan.
- Klembord ophalen staat standaard uit en slaat vertrouwelijke, tijdelijke en automatisch gemaakte klembordinhoud over (`org.nspasteboard.*`).
- `build.sh` kan ondertekenen met een Developer ID en de app laten notariseren.

Overig:

- Over-venster met versie, build, commit, builddatum, macOS-versie en de status van sandbox, Hardened Runtime en handtekening; **Kopieer versie-informatie** in het app-menu.
- Nederlands als basistaal van de app.

Let op: instellingen staan nu in de sandboxcontainer. Kies je screenshotmap opnieuw en voeg je Hot Spaces opnieuw toe.

## 1.0.0

Eerste versie.

- Tabs **In geheugen** en **Opgeslagen**; een Hot Space opent als eigen tab.
- Screenshot maken vanuit de app (⌘N) en ophalen van het klembord.
- Opslaan per kaart, ⌘S, ⌘⇧S of via Hot Spaces (slepen, klikken, ⌘1 t/m ⌘9).
- Ongedaan maken na opslaan, verplaatsen, kopiëren en weggooien.
- Hot Spaces volgen hun map als die wordt hernoemd of verplaatst.
- Waarschuwing bij stoppen als er nog screenshots in het geheugen staan.
- Bouwt met alleen de Command Line Tools, inclusief app-icoon.
