# Marke – Software Regisseur

Logo „Cue Frame“: vier Sucherecken eines Kamerasuchers rahmen ein geometrisches R. Der Regisseur legt die Einstellung fest.
Der Entwurf entstand mit Codex (siehe `logo-entwuerfe/`, Konzept 1).

## Farben

| Rolle | Wert |
|---|---|
| Zeichen (Ochsenblut) | `#7C302D` |
| Hintergrund (Papier) | `#F2EBDD` |

## Dateien

| Datei | Zweck |
|---|---|
| `logo-mark.svg` | Zeichen ohne Hintergrund, 512 × 512 |
| `app-icon-ios.svg` | iOS-App-Icon, vollflächig; iOS setzt die Eckenmaske selbst |
| `app-icon-macos.svg` | macOS-App-Icon im macOS-Raster (824er Körper, 100 px Rand) |
| `menubar-template.svg` | Menüleisten-Symbol, 16 pt, auf dem @2x-Raster gezeichnet; liegt als Vektor-Template in `Apps/SoftwareRegisseur-macOS/Resources/Assets.xcassets/MenuBarIcon.imageset` |

Nach Änderungen an den App-Icon-Vorlagen die PNGs neu erzeugen:

```bash
Scripts/brand/render-app-icons.sh
```

Das Menüleisten-Symbol zeigt das Logo, solange der Dienst läuft oder geprüft wird. Braucht der Dienst Aufmerksamkeit (pausiert, gestoppt, nicht erreichbar, Konfigurationsfehler), erscheint stattdessen das jeweilige Statussymbol.
