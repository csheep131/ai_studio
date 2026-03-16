# Safe HuggingFace Download System

## Problem

Bisherige Downloads von HuggingFace-Modellen hatten folgende Risiken:

1. **Unkontrollierte Snapshot-Downloads** – `snapshot_download()` ohne Filter lud komplette Repos
2. **Riesige Komponenten** – text_encoder/, transformer/ mit vielen GB wurden versehentlich geladen
3. **Keine Größenprüfung** – Downloads liefen bis die Platte voll war
4. **Kaputte Downloads** – Bei Abbruch blieben unvollständige Ordner liegen
5. **Kein Dry-Run** – Man sah nicht vorher, was geladen wird

## Lösung

Das neue System (`hf_safe_download.py`) verhindert diese Probleme durch:

- ✅ **Download-Plan vorab** – Zeigt alle Dateien und Gesamtgröße vor dem Download
- ✅ **Strikte Größenlimits** – Bricht ab wenn Limit überschritten (default: 40GB)
- ✅ **Komponenten-Filter** – Lädt nur benötigte Teile (z.B. KEIN VAE bei FLUX)
- ✅ **Dry-Run Modus** – Testen ohne Download
- ✅ **Safe Mode** – Nur Metadaten, keine großen Gewichte
- ✅ **Cleanup bei Fehlern** – Kaputte Downloads werden bereinigt
- ✅ **Validierung** – Prüft ob Download vollständig ist

## Dateien

- `hf_safe_download.py` – Python-Modul für sichere Downloads
- `setup_remote_v3.sh` – Bash-Skript ruft Python-Modul auf

## Verwendung

### 1. Dry-Run (empfohlen vor erst Download)

```bash
# Zeigt was geladen würde, ohne zu downloaden
python3 hf_safe_download.py --model black-forest-labs/FLUX.2-dev --dry-run

# Mit JSON-Output für Skripte
python3 hf_safe_download.py --model FLUX.2-dev --dry-run --json
```

**Beispiel-Output:**
```
======================================================================
DOWNLOAD PLAN: black-forest-labs/FLUX.2-dev
======================================================================
Target Directory: /opt/models/FLUX.2-dev
Max Size Limit: 50.0GB
Total Files: 47
Total Size: 46.23GB (47338MB)
Fits Within Limit: YES ✓

Warnings (0):

Component Breakdown:
  transformer           35123.4MB ( 75.9%)
  text_encoder           2048.1MB (  4.4%)
  tokenizer                 0.5MB (  0.0%)
  scheduler                 0.1MB (  0.0%)
  model_index               0.0MB (  0.0%)

Files (47 total, showing first 20):
  transformer/config.json                               0.0MB
  transformer/diffusion_pytorch_model-00001-of-00003.safetensors 12345.6MB
  ...
======================================================================
```

### 2. Safe Mode (nur Metadaten)

```bash
# Lädt NUR Metadaten, keine großen .safetensors Dateien
python3 hf_safe_download.py --model FLUX.2-dev --safe-mode
```

Nützlich für:
- Testing
- Schnelles Prüfen ob Modell verfügbar
- CI/CD Pipelines

### 3. Normaler Download (mit Limits)

```bash
# Standard-Download mit automatischen Limits
python3 hf_safe_download.py --model black-forest-labs/FLUX.2-dev

# Mit explizitem Limit
python3 hf_safe_download.py --model FLUX.2-dev --max-size-gb 45

# Mit eigenem Output-Verzeichnis
python3 hf_safe_download.py --model FLUX.2-dev --output /mnt/data/models/flux
```

### 4. Spezifische Komponenten

```bash
# Nur Text-Encoder und Tokenizer (z.B. für Testing)
python3 hf_safe_download.py --model FLUX.2-dev --components text_encoder,tokenizer

# Nur Scheduler und Config
python3 hf_safe_download.py --model FLUX.2-dev --components scheduler,model_index
```

### 5. In setup_remote_v3.sh

Das Bash-Skript verwendet automatisch das sichere Download-System:

```bash
# Wird automatisch von setup_remote_v3.sh aufgerufen
STACK_TYPE=image_prompt PULL_MODEL=1 bash setup_remote_v3.sh

# Das Skript ruft hf_safe_download.py mit den richtigen Parametern
```

## Modell-Konfigurationen

### FLUX.2-dev / FLUX.1-dev
- **Limit:** 50 GB
- **Enthalten:** model_index, scheduler, text_encoder, tokenizer, transformer
- **Ausgeschlossen:** vae, image_encoder, feature_extractor
- **Begründung:** FLUX verwendet separaten VAE, nicht im Haupt-Repo

### SDXL
- **Limit:** 10 GB
- **Enthalten:** Alle Komponenten (text_encoder, unet, vae, tokenizer, etc.)
- **Ausgeschlossen:** Keine

### Wan2.1-T2V / Wan2.1-I2V
- **Limit:** 45 GB
- **Enthalten:** model_index, scheduler, tokenizer, text_encoder, transformer, vae
- **Ausgeschlossen:** Keine

## API-Referenz

### Python-Funktionen

```python
from hf_safe_download import (
    build_download_plan,
    safe_snapshot_download,
    validate_model_dir,
    cleanup_partial_model_dir,
)

# Download-Plan erstellen
plan = build_download_plan(
    model_id="black-forest-labs/FLUX.2-dev",
    target_dir="/opt/models/flux",
    max_size_gb=50,
    safe_mode=False,
)

# Plan anzeigen
print(f"Files: {plan.file_count}")
print(f"Size: {plan.total_size_gb:.2f}GB")
print(f"Fits limit: {plan.fits_within_limit()}")

# Download ausführen
success = safe_snapshot_download(plan, token="hf_...")

# Validierung
is_valid, reason = validate_model_dir("/opt/models/flux", "FLUX.2-dev")
if not is_valid:
    print(f"Invalid: {reason}")
    cleanup_partial_model_dir("/opt/models/flux")
```

### Bash-Aufruf

```bash
# In setup_remote_v3.sh
pull_hf_model_safe "black-forest-labs/FLUX.2-dev" "image_prompt"
```

## Fehlerbehandlung

### Download zu groß
```
✗ [12:34:56] Download exceeds size limit! (52.34GB > 50GB)
```
**Lösung:** `--max-size-gb` erhöhen oder Komponenten einschränken

### Platte voll
```
✗ [12:34:56] Insufficient disk space: 30.5GB free, need 55.4GB
```
**Lösung:** Mehr Speicherplatz freigeben

### Inkompletter Download
```
⚠ [12:34:56] Existing download is incomplete: Missing model_index.json
▶ [12:34:56] Attempting to resume download (will clean up corrupted files)
```
**Lösung:** System bereinigt automatisch und lädt neu

### Token fehlt (für gated repos)
```
⚠ [12:34:56] token missing for model download
```
**Lösung:** `HF_TOKEN` Umgebungsvariable setzen

## Best Practices

1. **Immer erst Dry-Run:**
   ```bash
   python3 hf_safe_download.py --model FLUX.2-dev --dry-run
   ```

2. **Safe-Mode für Testing:**
   ```bash
   python3 hf_safe_download.py --model FLUX.2-dev --safe-mode --dry-run
   ```

3. **Logs prüfen:**
   ```bash
   # Alle Downloads loggen
   python3 hf_safe_download.py --model FLUX.2-dev 2>&1 | tee download.log
   ```

4. **Validierung nach Download:**
   ```bash
   python3 -c "
   from hf_safe_download import validate_model_dir
   valid, reason = validate_model_dir('/opt/models/flux', 'FLUX.2-dev')
   print(f'Valid: {valid}, Reason: {reason}')
   "
   ```

## Migration von altem Code

### Alt (unsicher):
```python
from huggingface_hub import snapshot_download

snapshot_download(
    repo_id="black-forest-labs/FLUX.2-dev",
    local_dir="/opt/models/flux",
)
```

### Neu (sicher):
```python
from hf_safe_download import build_download_plan, safe_snapshot_download

plan = build_download_plan(
    model_id="black-forest-labs/FLUX.2-dev",
    target_dir="/opt/models/flux",
    max_size_gb=50,
)

if not plan.fits_within_limit():
    raise Exception(f"Download too large: {plan.total_size_gb}GB")

safe_snapshot_download(plan)
```

## Troubleshooting

### "Download exceeds size limit"
- Dry-Run um zu sehen welche Dateien zu groß sind
- `--components` um nur benötigte Teile zu laden
- `--max-size-gb` explizit setzen wenn Limit bekannt ist

### "Insufficient disk space"
- `df -h` um freien Platz zu prüfen
- Alte Modelle löschen: `rm -rf /opt/models/*/model/*`
- Größere Instanz mit mehr Storage mieten

### "Failed to list repo files"
- HF_TOKEN prüfen: `echo $HF_TOKEN`
- Netzwerkverbindung testen: `curl https://huggingface.co`
- Repo-Name prüfen: Existiert das Modell?

### Download bricht ab
- Logfile prüfen: `tail -100 /var/log/stack/*.log`
- Teilweise Downloads werden automatisch bereinigt
- Mit `--no-resume` erzwingen dass komplett neu geladen wird

## Sicherheitshinweise

1. **HF_TOKEN nie im Code hardcoden** – Immer Umgebungsvariable nutzen
2. **Max-Size-Limits nie deaktivieren** – Immer Schutz behalten
3. **Dry-Run vor neuen Modellen** – Unbekannte Repos zuerst testen
4. **Logs überwachen** – Unerwartete Downloads sofort erkennen
