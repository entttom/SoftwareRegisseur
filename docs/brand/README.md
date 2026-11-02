# Marke – Software Regisseur

Logo „Oktopus mit drei Karten“: Ein freundlicher Oktopus koordiniert mit vier Armen die Arbeit mehrerer Agenten. Die drei Karten zeigen den Ablauf: `>_` (läuft), ein Git-Branch-Zeichen (eigener Zweig im Worktree) und ein Häkchen (freigegeben). Der Regisseur hält die Fäden in der Hand.
Das Bild entstand per KI-Bildgenerierung in mehreren Entwurfsrunden; gewählt wurde die Variante „Z3“ (untere Karte wird von einem Arm gegriffen). Die ersten Entwürfe der früheren Marke „Cue Frame“ (R im Sucherrahmen) liegen als verworfene Alternativen in `logo-entwuerfe/`.

## Farben

Aus dem App-Icon ausgelesen, daher als Näherungswerte zu verstehen.

| Rolle | Wert |
|---|---|
| Hintergrund und Symbole auf den Karten (Dunkelviolett) | `#28095C` |
| Oktopus (Koralle) | `#FC5635` |
| Karten (Creme) | `#FCF8EB` |

## Dateien

Das iOS-App-Icon ist zugleich die Vorlage („Master“) für alle anderen Größen. Es gibt keine Vektorvorlage.

| Datei | Zweck |
|---|---|
| `Apps/SoftwareRegisseur-iOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` | iOS-App-Icon und Master, 1024 × 1024, vollflächig und ohne Alphakanal; iOS setzt die Eckenmaske selbst |
| `Apps/SoftwareRegisseur-macOS/Resources/Assets.xcassets/AppIcon.appiconset/` | macOS-App-Icon in zehn Größen (16 bis 512 pt, 1x und 2x), aus dem Master abgeleitet |
| `Apps/SoftwareRegisseur-macOS/Resources/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.svg` | Menüleisten-Symbol: einfarbige Oktopus-Silhouette mit zwei Karten, 16 pt, auf dem @2x-Raster gezeichnet, als Vektor-Template |

### macOS-Icon aus dem Master ableiten

Das macOS-Icon im macOS-Raster: Leinwand 1024 × 1024 px, transparent. In der Mitte sitzt der Master auf 824 × 824 px verkleinert (100 px Rand), mit abgerundeten Ecken (Radius etwa 22,4 % von 824, also rund 184 px). Alle kleineren Größen werden aus dieser 1024er-Leinwand heruntergerechnet. Ein Skript dafür gibt es nicht mehr; wer den Master austauscht, leitet die macOS-Größen auf diese Weise neu ab.

## Menüleiste

Das Menüleisten-Symbol zeigt das Logo, solange der Dienst läuft oder geprüft wird. Braucht der Dienst Aufmerksamkeit (pausiert, gestoppt, nicht erreichbar, Konfigurationsfehler), erscheint stattdessen das jeweilige Statussymbol.
