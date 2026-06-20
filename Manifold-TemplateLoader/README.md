# Manifold Template Loader

Der Loader registriert `.CEA`-Templates aus `Manifold-TemplateLoader-Templates` und erstellt den Kontext für ein Auto-Assembler-Script.

## Reload-Verhalten

- **Reload templates** entdeckt und registriert Templates einmal global neu. Bereits geöffnete Auto-Assembler-Fenster werden nicht verändert; ein neu geöffnetes Fenster verwendet die aktualisierte Template-Generation und erhält die gruppierten Menüs.
- **Hot reload modules and templates** lädt einen vollständigen Kandidaten aus Loader und Abhängigkeiten. Nach erfolgreicher Validierung werden alle offenen Auto-Assembler-Fenster zerstört, dann werden die Registrierungen auf die neue Instanz umgeschaltet. Ungespeicherte Scripts in diesen Fenstern gehen dabei verloren.
- Falls die Registrierung eines neuen Template-Satzes scheitert, versucht der Loader, den vorherigen Satz wiederherzustellen.

Der dauerhaft geladene Runtime-Host besitzt die einzige Form-Notification. Dadurch kann der Loader selbst ohne Neustart ausgetauscht werden. Nach dem Hot Reload erzeugt ein neues Auto-Assembler-Fenster die Settings und kategorisierten Templates aus der neuen Generation.

## Template-Einstellungen

Eine Datei `Name.Settings.lua` muss eine Tabelle zurückgeben. Die Datei läuft in einer kleinen Daten-Sandbox und kann daher keine Cheat-Engine- oder Dateisystem-APIs aufrufen.

```lua
return {
    Caption = "Pointer Hook",
    Shortcut = "",
    InSubMenu = true,
    SubMenuName = "[1] Hooks > Pointer",
    MenuOrder = 10,
    AskForInjectionAddress = true,
    AskForHookName = true,
    AppendToHookName = "Hook",
    AllocationSize = "$1000",
    AllocationNear = true,
    DefaultHookName = "Injection"
}
```

`>` erzeugt verschachtelte Menüs. Ein Präfix wie `[1]` steuert nur die Sortierung und wird im Menü nicht angezeigt. Template-Einstellungen überschreiben die globalen Memory-Defaults für dieses eine Template.

## Memory-Defaults

Im Menü **Template Loader → Memory defaults** lassen sich Hook-Abfrage, Adress-Abfrage, Allocation-Größe, nahe Allocation und der Default-Hookname konfigurieren. Der Loader berechnet Originalbytes und Originalopcodes stets für die komplette, tatsächlich überschriebenen Instruktionsspanne.

Mono/managed-runtime-Support ist bewusst noch nicht implementiert; der konkrete To-do-Einstieg befindet sich im Memory-Modul.
