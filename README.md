# AI Studio

AI Studio ist eine lokale Steuerung für mehrere GPU-Stacks auf Vast.ai. Das Projekt mietet Remote-Instanzen, richtet sie automatisch ein und öffnet bei Bedarf lokale SSH-Tunnel für Text-, Bild- und Video-Workloads.

Technischer Überblick: [TECHSTACK.md](/home/schaf/projects/ai_studio/TECHSTACK.md)

## Voraussetzungen

- Linux/macOS mit `bash`, `python3`, `jq`, `ssh`, `scp`
- Vast.ai CLI `vastai`
- funktionierender SSH-Key für Vast.ai
- optional ein Hugging-Face-Token für private oder limitierte Modelle

## Konfiguration

### 1. Vast.ai API-Key

Entweder:

- lokal in `.vastai_key`
- oder global in `~/.config/vastai/vast_api_key`

Beispiel:

```bash
echo 'DEIN_VAST_API_KEY' > .vastai_key
chmod 600 .vastai_key
```

### 2. Hugging Face Token

In `.env`:

```bash
HF_TOKEN=hf_xxx
```

Alternativ funktioniert auch `HUGGINGFACE_HUB_TOKEN`.

## Installation

Das Projekt selbst braucht lokal keine große Python-Installation. Die meisten Abhängigkeiten werden auf der Remote-Instanz installiert.

Sinnvoll lokal:

```bash
python3 --version
jq --version
vastai --help
```

Dann direkt:

```bash
chmod +x studio.sh manage_v7_fixed.sh vast.py setup_remote_v3.sh
```

## Schnellstart

### Interaktiv

```bash
./studio.sh
```

Wichtige Menüpunkte pro Stack:

- `1` Automatisch vorbereiten
- `2` Status aktualisieren
- `3` Tunnel/UI öffnen
- `4` Lokale State löschen
- `5` Remote zerstören
- `6` Modell aktualisieren, nur bei `text` und `text_pro`

### Direkt per Befehl

```bash
./studio.sh go text
./studio.sh go text_pro
./studio.sh go image
./studio.sh go video
```

`go` versucht automatisch:

1. Instanz finden oder mieten
2. Instanz starten
3. SSH prüfen
4. Setup ausführen
5. Dienst starten
6. Tunnel öffnen

## Wichtige Befehle

### Studio UI

```bash
./studio.sh
./studio.sh dashboard
./studio.sh doctor text
./studio.sh logs video --follow
./studio.sh repair image
./studio.sh status
```

### Low-Level Management

```bash
./manage_v7_fixed.sh rent text
./manage_v7_fixed.sh use image last
./manage_v7_fixed.sh setup text_pro
./manage_v7_fixed.sh start text_pro
./manage_v7_fixed.sh login image
./manage_v7_fixed.sh health video
./manage_v7_fixed.sh ensure-ready text
```

## Arbeitsweise

### `studio.sh`

Die empfohlene Oberfläche für den Alltag.

- zeigt Overview, Dashboard und Doctor
- kann Stacks automatisch vorbereiten
- öffnet Tunnel und Logs
- verwaltet den Video-Workflow

### `manage_v7_fixed.sh`

Direkter CLI-Zugang für einzelne Aktionen.

- rent
- use
- delete
- resume
- setup
- start
- repair
- login
- tunnel
- status
- health
- ensure-ready

### `vast.py`

Das Backend für:

- Vast-Angebotssuche und Instanz-Erstellung
- SSH-Auflösung
- Health-Checks
- Remote-Datei- und Port-Prüfungen
- Diagnose

## Modelle ändern

Für `text` und `text_pro` direkt im Menü:

```text
[6] Modell aktualisieren
```

Das aktualisiert:

- `stacks.yaml`
- Remote-Modellverzeichnis
- `/onstart.sh`
- den laufenden Dienst

## Logs

Remote-Logs liegen typischerweise unter:

- `/var/log/stack/text.log`
- `/var/log/stack/text_pro.log`
- `/var/log/stack/image.log`
- `/var/log/stack/video.log`

Lokal ansehen:

```bash
./studio.sh logs text --follow
./studio.sh logs image --follow
```

## Typischer Ablauf

### Text oder Text Pro

```bash
./studio.sh
```

Dann:

1. Stack öffnen
2. `1` Automatisch vorbereiten
3. `3` Tunnel/UI öffnen

### Image oder Video

```bash
./studio.sh
```

Dann:

1. Stack öffnen
2. `1` Automatisch vorbereiten
3. `3` Tunnel/UI öffnen

## Zustände und lokale Dateien

Lokale State-Dateien:

- `.vast_instance_text`
- `.vast_instance_text_pro`
- `.vast_instance_image`
- `.vast_instance_video`

Diese speichern die aktuelle Vast-Instanz-Zuordnung pro Stack.

## Fehlerbehebung

### Stack ist nicht bereit

```bash
./studio.sh doctor text
./studio.sh repair text
```

### Logs prüfen

```bash
./studio.sh logs text --follow
```

### State lokal zurücksetzen

Im Menü:

- `4` Lokale State löschen

Oder per CLI:

```bash
./manage_v7_fixed.sh delete text
```

### Remote komplett neu aufsetzen

Im Menü:

- `5` Remote zerstören

Oder per CLI:

```bash
./manage_v7_fixed.sh delete text --remote
```

## Hinweise

- Die Rechenarbeit läuft auf der Vast-Instanz, nicht lokal.
- Lokal laufen nur Orchestrierung, SSH und Tunnel.
- Die Stack-Definitionen liegen vollständig in [stacks.yaml](/home/schaf/projects/ai_studio/stacks.yaml).
- Alte oder archivierte Inhalte liegen in `zukunft/` und sind nicht Teil des aktiven Betriebs.
