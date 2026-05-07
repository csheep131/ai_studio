/**
 * Alpine.js component for AI Studio Film UI
 */
function filmApp() {
  return {
    // State
    config: {},
    scenes: [],
    runs: {},
    logs: [],
    totalScenes: 0,
    stateStatus: 'no_runs',

    // UI state
    leftTab: 'config',
    running: false,
    currentCmd: '',
    showPilot: false,
    showGen: false,
    pilotFrom: 1,
    pilotTo: 10,
    genSelector: 'all',
    editingScene: null,
    _editingIdx: null,

    async init() {
      await Promise.all([this.refreshConfig(), this.refreshScenes(), this.refreshStatus()]);
    },

    // --- Data loaders ---
    async refreshConfig() {
      try {
        const r = await fetch('/api/workflow/config');
        this.config = await r.json();
      } catch(e) { this.addLog('error', 'Failed to load config: ' + e.message); }
    },

    async refreshScenes() {
      try {
        const r = await fetch('/api/workflow/scenes');
        const data = await r.json();
        this.scenes = data.scenes || [];
        this.totalScenes = this.scenes.length;
      } catch(e) { this.addLog('error', 'Failed to load scenes: ' + e.message); }
    },

    async refreshStatus() {
      try {
        const r = await fetch('/api/workflow/status');
        const data = await r.json();
        this.totalScenes = data.total_scenes;
        this.runs = data.runs || {};
        this.stateStatus = data.state?.run_id || data.state?.status || 'no_runs';
      } catch(e) { this.addLog('error', 'Failed to load status: ' + e.message); }
    },

    // --- Config ---
    async saveConfig() {
      try {
        const r = await fetch('/api/workflow/config', {
          method: 'PUT',
          headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({config: this.config}),
        });
        const data = await r.json();
        if (data.ok) { this.addLog('log', 'Config saved.'); }
        else { this.addLog('error', 'Config save failed.'); }
      } catch(e) { this.addLog('error', 'Save error: ' + e.message); }
    },

    // --- Scenes ---
    async saveScenes() {
      try {
        const r = await fetch('/api/workflow/scenes', {
          method: 'PUT',
          headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({scenes: this.scenes}),
        });
        const data = await r.json();
        if (data.ok) { this.addLog('log', 'Scenes saved (' + data.count + ').'); }
      } catch(e) { this.addLog('error', 'Save scenes error: ' + e.message); }
    },

    editScene(idx) {
      this._editingIdx = idx;
      this.editingScene = JSON.parse(JSON.stringify(this.scenes[idx]));
    },

    async saveEditingScene() {
      if (this._editingIdx !== null && this.editingScene) {
        this.scenes[this._editingIdx] = this.editingScene;
        this.editingScene = null;
        this._editingIdx = null;
        await this.saveScenes();
      }
    },

    // --- Workflow Commands (with SSE streaming) ---
    async runCmd(command, args = '') {
      if (this.running) return;
      this.running = true;
      this.currentCmd = command;
      this.logs = [];
      this.addLog('log', '==> Starting: ' + command + (args ? ' ' + args : ''));

      try {
        const url = '/api/stream/logs?command=' + encodeURIComponent(command) +
                    (args ? '&args=' + encodeURIComponent(args) : '');
        const resp = await fetch(url);

        const reader = resp.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';

        while (true) {
          const {done, value} = await reader.read();
          if (done) break;

          buffer += decoder.decode(value, {stream: true});
          const parts = buffer.split('\n\n');
          buffer = parts.pop(); // keep incomplete chunk

          for (const part of parts) {
            if (!part.startsWith('data: ')) continue;
            try {
              const evt = JSON.parse(part.slice(6));
              if (evt.type === 'log') {
                this.addLog('log', evt.data);
              } else if (evt.type === 'done') {
                this.addLog(evt.returncode === 0 ? 'done' : 'error',
                            evt.returncode === 0 ? '==> Done (rc=0)' : '==> Failed (rc=' + evt.returncode + ')');
              } else if (evt.type === 'error') {
                this.addLog('error', evt.data);
              }
            } catch(e) { /* skip malformed events */ }
          }
        }
      } catch(e) {
        this.addLog('error', 'Connection error: ' + e.message);
      }

      this.running = false;
      this.currentCmd = '';
      // Refresh data after command completes
      await Promise.all([this.refreshConfig(), this.refreshScenes(), this.refreshStatus()]);
    },

    // --- Log helper ---
    addLog(type, data) {
      this.logs.push({type, data});
      this.$nextTick(() => {
        const el = this.$refs.logContainer;
        if (el) el.scrollTop = el.scrollHeight;
      });
    },
  };
}
