# Wijzigingen

Het versienummer staat in `VERSION`. Het buildnummer is het aantal commits; samen met de commit en de builddatum zie je het in **Screenshot Hub › Over Screenshot Hub**.

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
