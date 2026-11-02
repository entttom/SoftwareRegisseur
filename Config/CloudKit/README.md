# CloudKit-Schema

`schema.ckdb` ist das Schema des Containers `SR_CLOUDKIT_CONTAINER` (Private Database, Zone `SoftwareRegisseur`) in der CloudKit Schema Language. Es entspricht `SyncRecordSchema` in `Packages/SoftwareRegisseurSync`: 23 Datensatztypen mit je denselben 10 Feldern, dazu der Systemtyp `Users`.

Alle Builds verwenden die Umgebung **Production** (ADR-0027). CloudKit legt dort keine Typen oder Felder automatisch an. Ein neuer Datensatztyp oder ein neues Feld kommt deshalb immer über diese Datei:

1. `schema.ckdb` anpassen (Production ist nur additiv: Typen und Felder lassen sich nicht löschen oder umbenennen).
2. Einmalig einen Management-Token speichern (CloudKit Console → Tokens): `xcrun cktool save-token --type management`.
3. Prüfen und nach Development importieren:

   ```bash
   xcrun cktool validate-schema --team-id <TEAM> --container-id <CONTAINER> --environment development --file Config/CloudKit/schema.ckdb
   xcrun cktool import-schema --team-id <TEAM> --container-id <CONTAINER> --environment development --file Config/CloudKit/schema.ckdb
   ```

4. In der CloudKit Console (Umgebung Development) **Deploy Schema Changes…** ausführen.
5. Gegenprobe: `xcrun cktool export-schema … --environment production` muss dieser Datei entsprechen.

Erst danach eine App-Version ausliefern, die den neuen Typ oder das neue Feld schreibt. Sonst lehnt Production die Datensätze ab.

Team-ID und Container stehen nur in `Config/Local.xcconfig` (ADR-0013).
