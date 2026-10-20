# Wijzigingen

Het versienummer staat in `VERSION`. Het buildnummer is het aantal commits; samen met de commit en de builddatum zie je het in **Screenshot Hub › Over Screenshot Hub**.

## 1.3.0

- **Updatemelding**: de app kijkt hooguit één keer per dag bij GitHub of er een nieuwere versie is en toont dan bovenin een melding met een knop naar de release. **Niet nu** verbergt de melding tot de volgende versie.
- **Screenshot Hub › Controleer op updates…** controleert direct; **Dagelijks controleren op updates** zet de check aan of uit (standaard aan). De eerste keer legt de app uit dat hij contact maakt met GitHub.
- De app downloadt of installeert niets zelf. Alleen tags als `v1.2.3` tellen mee, het antwoord mag hooguit 2 MB zijn, en de link naar de release maakt de app zelf.
- Nieuw recht `com.apple.security.network.client`, alleen voor deze check. Het Over-venster laat zien of de check aan staat.

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
- `bash build.sh --dmg` maakt een DMG in `dist/` met de app en een snelkoppeling naar Programma's; `--release` maakt die DMG ook, en ondertekent, notariseert en staplet hem.

Releases:

- GitHub Actions bouwt de app en de DMG bij elke pull request en elke wijziging op main. De pre-release **Laatste build** bevat altijd de nieuwste build van main, en elke nieuwe versie in `VERSION` krijgt een eigen release met de DMG.

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
