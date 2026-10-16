# Screenshot Hub

**Shoot first, store later.** Een kleine macOS-app waarin screenshots eerst in het geheugen komen. Pas als je ze opslaat worden het bestanden: in je screenshotmap of meteen in de juiste map via een Hot Space.

![Screenshot Hub](docs/screenshot.png)

## Wat het doet

- **In geheugen**: screenshots die nog niet zijn opgeslagen.
  - Maak er een met de knop **Screenshot maken** (⌘N): kies een gebied, of druk op spatie voor een venster.
  - Of maak er een naar het klembord met ⌃⌘⇧4. Elke afbeelding die op het klembord komt, verschijnt hier; dat kun je uitzetten met **Klembord ophalen**.
  - Opslaan kan per kaart, met ⌘S voor de selectie of met **Alles opslaan** (⌘⇧S).
- **Opgeslagen**: wat er in je screenshotmap staat. Standaard is dat de map die macOS gebruikt (instelbaar via ⌘⇧5 › Opties); je kunt een andere map kiezen.
- **Hot Spaces**: mappen in de zijbalk waar je screenshots naartoe stuurt.
  - Sleep een screenshot op een Hot Space, klik erop met een selectie, of druk ⌘1 t/m ⌘9.
  - Screenshots uit het geheugen worden daar opgeslagen. Opgeslagen screenshots worden verplaatst of gekopieerd, naar keuze.
  - Klik op een Hot Space zonder selectie, of op het oog, om te zien wat erin staat.
  - Hernoem of verplaats je de map in Finder, dan blijft de Hot Space gewoon werken.
- **Ongedaan maken**: na opslaan, verplaatsen, kopiëren of weggooien staat er een knop in de melding onderin.
- **Veilig stoppen**: staan er nog screenshots in het geheugen, dan vraagt de app bij stoppen of je ze wilt opslaan.

## Sneltoetsen

| Toets | Actie |
| --- | --- |
| ⌘N | Nieuwe screenshot in het geheugen |
| ⌘S | Geselecteerde screenshots opslaan in de screenshotmap |
| ⌘⇧S | Alles uit het geheugen opslaan |
| ⌘1 t/m ⌘9 | Selectie naar Hot Space 1 t/m 9 |
| Esc | Selectie wissen |
| Klik, ⌘-klik, ⇧-klik | Selecteren, toevoegen of weghalen, reeks selecteren |
| Dubbelklik | Opgeslagen screenshot openen |

## Bouwen

Nodig: macOS 13 of nieuwer en de Command Line Tools. Xcode is niet nodig.

```sh
xcode-select --install   # eenmalig, als je de Command Line Tools nog niet hebt
bash build.sh
open "Screenshot Hub.app"
```

`build.sh` compileert de app, tekent het icoon en ondertekent de app lokaal. Sleep `Screenshot Hub.app` daarna naar Programma's.

## Toestemmingen

- **Schermopname**: macOS vraagt hierom de eerste keer dat je **Screenshot maken** gebruikt. Omdat de app bij elke build een nieuwe lokale handtekening krijgt, kan macOS na een nieuwe build opnieuw om toestemming vragen.
- **Bureaublad, Documenten en Downloads**: macOS vraagt hierom zodra de app een map daarin opent.

## Bestanden

| Bestand | Inhoud |
| --- | --- |
| `ScreenshotHub.swift` | De hele app (SwiftUI) |
| `AppIcon.swift` | Tekent het app-icoon; `build.sh` maakt er een `.icns` van |
| `build.sh` | Bouwt `Screenshot Hub.app` |
| `docs/screenshot.png` | De afbeelding hierboven |
