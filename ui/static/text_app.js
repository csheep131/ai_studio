/**
 * Text/Drehbuch Editor App
 * Alpine.js Logic for the Script Editor
 */

function textApp() {
  return {
    // ─────────────────────────────────────────────────────────────────────────
    // State: Data
    // ─────────────────────────────────────────────────────────────────────────

    currentScript: null,
    scenes: [],
    savedScripts: [],
    availableClips: [],
    filmStatus: null,

    // ─────────────────────────────────────────────────────────────────────────
    // State: UI
    // ─────────────────────────────────────────────────────────────────────────

    selectedScene: null,
    isGenerating: false,
    generationProgress: 0,
    generationStatus: '',
    errorMessage: '',
    localAiRunning: false,

    // ─────────────────────────────────────────────────────────────────────────
    // State: Prompts & Settings
    // ─────────────────────────────────────────────────────────────────────────

    selectedTemplate: 'standard',
    systemPrompt: '',
    userPrompt: '',
    targetScenes: 5,
    temperature: 0.7,
    newScriptTitle: '',

    // ─────────────────────────────────────────────────────────────────────────
    // State: Modals
    // ─────────────────────────────────────────────────────────────────────────

    showNewScriptModal: false,
    showLoadModal: false,
    showExportModal: false,

    // ─────────────────────────────────────────────────────────────────────────
    // State: Toast Notifications
    // ─────────────────────────────────────────────────────────────────────────

    toasts: [],
    autoSaveEnabled: true,
    lastSaved: null,
    hasUnsavedChanges: false,
    originalScenesHash: '',

    // ─────────────────────────────────────────────────────────────────────────
    // Template Presets
    // ─────────────────────────────────────────────────────────────────────────

    templates: {
      standard: `Du bist ein erfahrener Drehbuchautor für KI-generierte Videos.

AUFGABE: Erstelle ein detailliertes Drehbuch im JSON-Format.

STRUKTUR:
- 3-Akt-Struktur (Akt 1: Setup 25%, Akt 2: Konfrontation 50%, Akt 3: Auflösung 25%)
- Jede Szene: Nummer, Akt, Titel, Beschreibung, Visual-Prompt, Keywords, Dauer
- Visual-Prompts müssen KI-Video-optimiert sein (englisch, deskriptiv)

WICHTIG: Antworte AUSSCHLIEßLICH mit validem JSON. Keine Erklärungen, kein Markdown.

FORMAT:
{
  "title": "Drehbuch-Titel",
  "scenes": [
    {
      "scene_number": 1,
      "act": 1,
      "title": "Szene-Titel",
      "description": "Detaillierte Beschreibung...",
      "visual_prompt": "cinematic wide shot, detailed environment, atmospheric lighting, 4k quality",
      "keywords": "stimmungsvoll, dramatisch",
      "duration_seconds": 5
    }
  ]
}`,

      short: `Du bist ein Drehbuchautor für Kurzfilme (1-3 Minuten).

AUFGABE: Erstelle ein kompaktes Drehbuch im JSON-Format.

EIGENSCHAFTEN:
- Maximal 10 Szenen
- Schneller Erzählrhythmus
- Klare emotionale Bogen
- Prägnante visuelle Beschreibungen
- Jede Szene 3-8 Sekunden

WICHTIG: Antworte AUSSCHLIEßLICH mit validem JSON.`,

      commercial: `Du bist ein Werbetexter für Kurzspots (15-30 Sekunden).

AUFGABE: Erstelle ein Werbedrehbuch im JSON-Format.

STRUKTUR:
- Hook in ersten 3 Sekunden
- Problem/Desire Aufbau
- Lösung/Produkt
- Call-to-Action
- Maximal 6 Szenen

WICHTIG: Antworte AUSSCHLIEßLICH mit validem JSON.`,

      musicvideo: `Du bist ein Creative Director für Musikvideos.

AUFGABE: Erstelle ein Musikvideo-Drehbuch im JSON-Format.

EIGENSCHAFTEN:
- Visuell atmosphärisch
- Rhythmisches Editing
- Abstrakte + narrative Elemente
- Wiederkehrende Motive
- Starke Farbgestaltung

WICHTIG: Antworte AUSSCHLIEßLICH mit validem JSON.`,

      tutorial: `Du bist ein Instructional Designer für Erklärvideos.

AUFGABE: Erstelle ein Tutorial-Drehbuch im JSON-Format.

STRUKTUR:
- Einleitung: Was lernen wir?
- Schritt-für-Schritt (jeder Schritt = eine Szene)
- Visuelle Detail-Fokussierung
- Zusammenfassung am Ende
- Klare, einfache Sprache

WICHTIG: Antworte AUSSCHLIEßLICH mit validem JSON.`,

      custom: ''
    },

    // ─────────────────────────────────────────────────────────────────────────
    // Lifecycle
    // ─────────────────────────────────────────────────────────────────────────

    init() {
      this.loadTemplate();
      this.checkLocalAi();
      this.loadSavedScripts();
      this.loadAvailableClips();

      // Create empty script if none exists
      if (!this.currentScript) {
        this.createNewScript('Neues Drehbuch');
      } else {
        this.loadFilmStatus();
      }

      // Setup auto-save interval
      setInterval(() => {
        if (this.autoSaveEnabled && this.hasUnsavedChanges && this.currentScript) {
          this.autoSave();
        }
      }, 30000); // Auto-save every 30 seconds

      // Setup keyboard shortcuts
      this.setupKeyboardShortcuts();

      // Watch for changes
      this.$watch('scenes', () => {
        this.checkForChanges();
      }, { deep: true });

      // Warn before leaving with unsaved changes
      window.addEventListener('beforeunload', (e) => {
        if (this.hasUnsavedChanges) {
          e.preventDefault();
          e.returnValue = '';
        }
      });
    },

    // ─────────────────────────────────────────────────────────────────────────
    // Toast Notifications
    // ─────────────────────────────────────────────────────────────────────────

    showToast(message, type = 'info', duration = 3000) {
      const id = Date.now();
      this.toasts.push({ id, message, type, duration });

      setTimeout(() => {
        this.toasts = this.toasts.filter(t => t.id !== id);
      }, duration);
    },

    // ─────────────────────────────────────────────────────────────────────────
    // Auto-Save
    // ─────────────────────────────────────────────────────────────────────────

    checkForChanges() {
      const currentHash = JSON.stringify(this.scenes);
      this.hasUnsavedChanges = currentHash !== this.originalScenesHash;
    },

    async autoSave() {
      if (!this.currentScript || !this.hasUnsavedChanges) return;

      try {
        await this.saveScript(true);
        this.showToast('Automatisch gespeichert', 'success', 2000);
      } catch (e) {
        console.error('Auto-save failed:', e);
      }
    },

    // ─────────────────────────────────────────────────────────────────────────
    // Keyboard Shortcuts
    // ─────────────────────────────────────────────────────────────────────────

    setupKeyboardShortcuts() {
      document.addEventListener('keydown', (e) => {
        // Ctrl/Cmd + S: Save
        if ((e.ctrlKey || e.metaKey) && e.key === 's') {
          e.preventDefault();
          this.saveScript();
        }

        // Ctrl/Cmd + N: New Script
        if ((e.ctrlKey || e.metaKey) && e.key === 'n') {
          e.preventDefault();
          this.showNewScriptModal = true;
        }

        // Escape: Close modals
        if (e.key === 'Escape') {
          this.showNewScriptModal = false;
          this.showLoadModal = false;
          this.showExportModal = false;
        }
      });
    },

    // ─────────────────────────────────────────────────────────────────────────
    // Template Management
    // ─────────────────────────────────────────────────────────────────────────

    loadTemplate() {
      this.systemPrompt = this.templates[this.selectedTemplate] || '';
    },

    // ─────────────────────────────────────────────────────────────────────────
    // Local AI Status
    // ─────────────────────────────────────────────────────────────────────────

    async checkLocalAi() {
      try {
        const r = await fetch('/api/local/ai/status');
        const data = await r.json();
        this.localAiRunning = data.running;
      } catch (e) {
        this.localAiRunning = false;
      }
    },

    async refreshStatus() {
      await this.checkLocalAi();
      await this.loadSavedScripts();
      await this.loadAvailableClips();
      await this.loadFilmStatus();
    },

    // ─────────────────────────────────────────────────────────────────────────
    // Script Management
    // ─────────────────────────────────────────────────────────────────────────

    createNewScript(title) {
      this.currentScript = {
        id: 'script_' + Date.now(),
        title: title || 'Neues Drehbuch',
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        prompt: '',
        system_prompt: this.systemPrompt,
        exported_to_film: false,
        film_run_id: null
      };
      this.scenes = [];
      this.newScriptTitle = '';
      this.showNewScriptModal = false;
      this.errorMessage = '';

      // Reset change tracking
      this.$nextTick(() => {
        this.originalScenesHash = JSON.stringify(this.scenes);
        this.hasUnsavedChanges = false;
      });

      this.showToast('Neues Drehbuch erstellt', 'info');
    },

    async loadSavedScripts() {
      try {
        const r = await fetch('/api/text/scripts');
        const data = await r.json();
        this.savedScripts = data.scripts || [];
      } catch (e) {
        console.error('Failed to load saved scripts:', e);
        this.savedScripts = [];
      }
    },

    async loadScript(scriptId) {
      try {
        const r = await fetch(`/api/text/scripts/${scriptId}`);
        if (!r.ok) throw new Error('Script not found');

        const data = await r.json();
        this.currentScript = data.script;
        this.scenes = data.scenes || [];
        this.showLoadModal = false;
        this.errorMessage = '';

        // Reset change tracking after load
        this.$nextTick(() => {
          this.originalScenesHash = JSON.stringify(this.scenes);
          this.hasUnsavedChanges = false;
        });

        this.showToast(`"${this.currentScript.title}" geladen`, 'success');
        await this.loadFilmStatus();
      } catch (e) {
        console.error('Failed to load script:', e);
        this.errorMessage = 'Fehler beim Laden des Drehbuchs';
        this.showToast('Laden fehlgeschlagen', 'error');
      }
    },

    async saveScript(isAutoSave = false) {
      if (!this.currentScript) return;

      const payload = {
        script: {
          ...this.currentScript,
          updated_at: new Date().toISOString()
        },
        scenes: this.scenes
      };

      try {
        const r = await fetch('/api/text/scripts', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload)
        });

        if (!r.ok) throw new Error('Save failed');

        // Update hash after successful save
        this.originalScenesHash = JSON.stringify(this.scenes);
        this.hasUnsavedChanges = false;
        this.lastSaved = new Date();

        await this.loadSavedScripts();
        this.errorMessage = '';

        if (!isAutoSave) {
          this.showToast('Drehbuch gespeichert!', 'success');
        }
      } catch (e) {
        console.error('Failed to save script:', e);
        this.errorMessage = 'Fehler beim Speichern';
        if (!isAutoSave) {
          this.showToast('Speichern fehlgeschlagen', 'error');
        }
      }
    },

    async deleteSavedScript(scriptId) {
      if (!confirm('Drehbuch wirklich löschen?')) return;

      try {
        const r = await fetch(`/api/text/scripts/${scriptId}`, {
          method: 'DELETE'
        });

        if (!r.ok) throw new Error('Delete failed');

        this.showToast('Drehbuch gelöscht', 'info');
        await this.loadSavedScripts();

        // If current script was deleted, create new one
        if (this.currentScript?.id === scriptId) {
          this.createNewScript('Neues Drehbuch');
        }
      } catch (e) {
        console.error('Failed to delete script:', e);
        this.errorMessage = 'Fehler beim Löschen';
        this.showToast('Löschen fehlgeschlagen', 'error');
      }
    },

    // ─────────────────────────────────────────────────────────────────────────
    // Scene Management
    // ─────────────────────────────────────────────────────────────────────────

    addScene() {
      // Max scenes limit
      if (this.scenes.length >= 100) {
        this.showToast('Maximale Anzahl an Szenen (100) erreicht', 'error');
        return;
      }

      const sceneNum = this.scenes.length + 1;
      const newScene = {
        id: 'scene_' + Date.now() + '_' + Math.random().toString(36).substr(2, 5),
        scene_number: sceneNum,
        act: this.guessActForScene(sceneNum),
        title: `Szene ${sceneNum}`,
        description: '',
        visual_prompt: '',
        keywords: '',
        duration_seconds: 5,
        ref: '',
        notes: ''
      };
      this.scenes.push(newScene);

      // Scroll to new scene
      this.$nextTick(() => {
        const container = this.$refs.scenesContainer;
        if (container) {
          container.scrollTop = container.scrollHeight;
        }
      });
    },

    validateScene(scene) {
      const errors = [];

      if (!scene.title || scene.title.trim().length === 0) {
        errors.push('Titel erforderlich');
      }

      if (scene.title && scene.title.length > 100) {
        errors.push('Titel zu lang (max 100 Zeichen)');
      }

      if (scene.duration_seconds < 1 || scene.duration_seconds > 60) {
        errors.push('Dauer muss zwischen 1 und 60 Sekunden liegen');
      }

      if (scene.description && scene.description.length > 1000) {
        errors.push('Beschreibung zu lang (max 1000 Zeichen)');
      }

      return errors;
    },

    validateAllScenes() {
      let totalErrors = 0;
      for (const scene of this.scenes) {
        const errors = this.validateScene(scene);
        if (errors.length > 0) {
          totalErrors += errors.length;
        }
      }
      return totalErrors;
    },

    guessActForScene(sceneNum) {
      const total = this.targetScenes || 5;
      const ratio = sceneNum / total;
      if (ratio <= 0.25) return 1;
      if (ratio <= 0.75) return 2;
      return 3;
    },

    deleteScene(index) {
      if (!confirm('Szene wirklich löschen?')) return;
      this.scenes.splice(index, 1);
      this.renumberScenes();
    },

    duplicateScene(index) {
      const original = this.scenes[index];
      const copy = { ...original, id: 'scene_' + Date.now() + '_copy' };
      this.scenes.splice(index + 1, 0, copy);
      this.renumberScenes();
    },

    moveScene(index, direction) {
      const newIndex = index + direction;
      if (newIndex < 0 || newIndex >= this.scenes.length) return;

      const temp = this.scenes[index];
      this.scenes[index] = this.scenes[newIndex];
      this.scenes[newIndex] = temp;

      this.renumberScenes();
    },

    renumberScenes() {
      this.scenes.forEach((scene, idx) => {
        scene.scene_number = idx + 1;
        scene.act = this.guessActForScene(idx + 1);
      });
    },

    // ─────────────────────────────────────────────────────────────────────────
    // LLM Generation (Streaming)
    // ─────────────────────────────────────────────────────────────────────────

    abortController: null,

    async generateScript() {
      if (!this.userPrompt || !this.localAiRunning) return;

      this.isGenerating = true;
      this.generationProgress = 5;
      this.generationStatus = 'Starte...';
      this.errorMessage = '';

      // Create abort controller for cancellation
      this.abortController = new AbortController();

      try {
        const response = await fetch('/api/text/generate/stream', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            user_prompt: this.userPrompt,
            system_prompt: this.systemPrompt,
            target_scenes: this.targetScenes,
            temperature: this.temperature
          }),
          signal: this.abortController.signal
        });

        if (!response.ok) {
          const err = await response.json();
          throw new Error(err.detail || 'Generation failed');
        }

        // Read SSE stream
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';

        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split('\n');
          buffer = lines.pop() || ''; // Keep incomplete line

          for (const line of lines) {
            if (line.startsWith('data: ')) {
              try {
                const data = JSON.parse(line.slice(6));
                this.handleStreamEvent(data);
              } catch (e) {
                console.warn('Failed to parse SSE data:', line);
              }
            }
          }
        }

      } catch (e) {
        if (e.name === 'AbortError') {
          this.generationStatus = 'Abgebrochen';
          setTimeout(() => {
            this.isGenerating = false;
            this.generationProgress = 0;
          }, 500);
        } else {
          console.error('Generation failed:', e);
          this.errorMessage = 'Fehler: ' + e.message;
          this.isGenerating = false;
          this.generationProgress = 0;
        }
      }
    },

    cancelGeneration() {
      if (this.abortController) {
        this.abortController.abort();
        this.abortController = null;
      }
    },

    handleStreamEvent(data) {
      this.generationProgress = data.progress || 0;
      this.generationStatus = data.message || '';

      switch (data.status) {
        case 'starting':
          // Verbindung wird hergestellt
          break;

        case 'generating':
          // LLM generiert - zeige ggf. Vorschau
          break;

        case 'parsing':
          // Antwort wird verarbeitet
          break;

        case 'complete':
          // Erfolgreich fertig - wende Ergebnis an
          if (data.result) {
            this.applyGeneratedScript(data.result);
          }
          setTimeout(() => {
            this.isGenerating = false;
            this.generationProgress = 0;
          }, 500);
          break;

        case 'error':
          // Fehler aufgetreten
          this.errorMessage = data.error || data.message || 'Unbekannter Fehler';
          this.isGenerating = false;
          this.generationProgress = 0;
          break;
      }
    },

    applyGeneratedScript(result) {
      // Apply generated content
      if (result.title) {
        this.currentScript.title = result.title;
      }
      if (result.scenes && Array.isArray(result.scenes)) {
        this.scenes = result.scenes.map((s, idx) => ({
          id: 'scene_' + Date.now() + '_' + idx,
          scene_number: s.scene_number || idx + 1,
          act: s.act || this.guessActForScene(idx + 1),
          title: s.title || '',
          description: s.description || '',
          visual_prompt: s.visual_prompt || s.description || '',
          keywords: s.keywords || '',
          duration_seconds: s.duration_seconds || 5,
          ref: '',
          notes: s.notes || ''
        }));
      }

      this.currentScript.prompt = this.userPrompt;
      this.currentScript.system_prompt = this.systemPrompt;
    },

    // ─────────────────────────────────────────────────────────────────────────
    // Clip Management
    // ─────────────────────────────────────────────────────────────────────────

    async loadAvailableClips() {
      try {
        const r = await fetch('/api/text/clips');
        this.availableClips = await r.json();
      } catch (e) {
        console.error('Failed to load clips:', e);
        this.availableClips = [];
      }
    },

    async assignClip(sceneId, clipId) {
      if (!this.currentScript) return;

      try {
        const r = await fetch(`/api/text/scripts/${this.currentScript.id}/assign-clip`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ scene_id: sceneId, clip_id: clipId })
        });

        if (!r.ok) throw new Error('Assignment failed');

        // Update local state
        const scene = this.scenes.find(s => s.id === sceneId);
        if (scene) {
          scene.ref = clipId;
        }
      } catch (e) {
        console.error('Failed to assign clip:', e);
        this.errorMessage = 'Clip-Zuordnung fehlgeschlagen';
      }
    },

    async loadFilmStatus() {
      if (!this.currentScript) return;

      try {
        const r = await fetch(`/api/text/scripts/${this.currentScript.id}/film-status`);
        if (r.ok) {
          this.filmStatus = await r.json();
        }
      } catch (e) {
        console.error('Failed to load film status:', e);
      }
    },

    async syncFromFilm() {
      if (!this.currentScript) return;

      try {
        const r = await fetch(`/api/text/scripts/${this.currentScript.id}/sync-from-film`, {
          method: 'POST'
        });

        if (!r.ok) throw new Error('Sync failed');

        const result = await r.json();

        if (result.updated_count > 0) {
          this.showToast(`${result.updated_count} Clip-Zuweisungen synchronisiert`, 'success');
          // Reload script to get updated refs
          await this.loadScript(this.currentScript.id);
          await this.loadFilmStatus();
        } else {
          this.showToast('Keine neuen Clips zum Synchronisieren gefunden', 'info');
        }
      } catch (e) {
        console.error('Sync failed:', e);
        this.errorMessage = 'Synchronisation fehlgeschlagen';
        this.showToast('Synchronisation fehlgeschlagen', 'error');
      }
    },

    getClipName(clipId) {
      const clip = this.availableClips.find(c => c.id === clipId);
      return clip ? clip.name : clipId;
    },

    getClipThumbnail(clipId) {
      const clip = this.availableClips.find(c => c.id === clipId);
      return clip ? clip.thumbnail : null;
    },

    // ─────────────────────────────────────────────────────────────────────────
    // Export
    // ─────────────────────────────────────────────────────────────────────────

    async exportToFilm() {
      if (!this.currentScript || this.scenes.length === 0) {
        this.showToast('Keine Szenen zum Exportieren', 'error');
        return;
      }

      // Validate before export
      const validationErrors = this.validateAllScenes();
      if (validationErrors > 0) {
        this.showToast(`${validationErrors} Validierungsfehler gefunden. Bitte korrigieren vor Export.`, 'error');
        return;
      }

      try {
        // First save current state
        await this.saveScript();

        const r = await fetch(`/api/text/export-to-film/${this.currentScript.id}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' }
        });

        if (!r.ok) throw new Error('Export failed');

        const data = await r.json();
        this.showExportModal = false;
        this.showToast(`${data.scenes_exported} Szenen exportiert!`, 'success');
        await this.loadFilmStatus();
      } catch (e) {
        console.error('Export failed:', e);
        this.errorMessage = 'Export fehlgeschlagen: ' + e.message;
        this.showToast('Export fehlgeschlagen', 'error');
      }
    },

    exportToJSON() {
      const payload = {
        script: this.currentScript,
        scenes: this.scenes
      };

      const blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = (this.currentScript?.title || 'drehbuch') + '.json';
      a.click();
      URL.revokeObjectURL(url);

      this.showExportModal = false;
    },

    // ─────────────────────────────────────────────────────────────────────────
    // Computed Properties
    // ─────────────────────────────────────────────────────────────────────────

    get totalDuration() {
      return this.scenes.reduce((sum, s) => sum + (parseInt(s.duration_seconds) || 0), 0);
    }
  };
}
