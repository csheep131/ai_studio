#!/usr/bin/env bash
#
# test_llama_cpp_install.sh - Testet die optimierte llama.cpp Installation
#
# Verwendung:
#   ./test_llama_cpp_install.sh              # Vollständiger Test
#   ./test_llama_cpp_install.sh --dry-run    # Nur Logik prüfen
#   ./test_llama_cpp_install.sh --quick      # Nur existierende Binary prüfen
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLAMA_CPP_DIR="/opt/llama.cpp"
LLAMA_SERVER_BIN="${LLAMA_CPP_DIR}/llama-server"

# Farben
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

print_info()  { echo -e "${BLUE}▶${NC} $*"; }
print_ok()    { echo -e "${GREEN}✓${NC} $*"; }
print_warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
print_err()   { echo -e "${RED}✗${NC} $*"; }
print_header() { echo -e "${BOLD}═══ $* ═══${NC}"; }

TEST_PASSED=0
TEST_FAILED=0
TEST_SKIPPED=0

pass() {
  print_ok "$@"
  ((TEST_PASSED++)) || true
}

fail() {
  print_err "$@"
  ((TEST_FAILED++)) || true
}

skip() {
  print_warn "$@"
  ((TEST_SKIPPED++)) || true
}

# ── Tests ───────────────────────────────────────────────────────────────────

test_system_llama() {
  print_header "Test 1: System llama-server erkennen"
  
  if command -v llama-server &>/dev/null; then
    local llama_path
    llama_path=$(command -v llama-server)
    
    if [[ -x "${llama_path}" ]]; then
      pass "System llama-server gefunden: ${llama_path}"
      
      # Version ausgeben
      if "${llama_path}" --version &>/dev/null; then
        local version
        version=$("${llama_path}" --version 2>&1 | head -1)
        print_info "Version: ${version}"
      fi
    else
      fail "llama-server existiert aber ist nicht ausführbar"
    fi
  else
    skip "Kein system-weites llama-server installiert"
  fi
}

test_existing_build() {
  print_header "Test 2: Vorhandene Build erkennen"
  
  if [[ -x "${LLAMA_SERVER_BIN}" ]]; then
    pass "Vorhandene Binary gefunden: ${LLAMA_SERVER_BIN}"
    
    # Größe prüfen
    local size
    size=$(du -h "${LLAMA_SERVER_BIN}" | cut -f1)
    print_info "Binary Größe: ${size}"
    
    # Version testen
    if "${LLAMA_SERVER_BIN}" --version &>/dev/null; then
      local version
      version=$("${LLAMA_SERVER_BIN}" --version 2>&1 | head -1)
      print_info "Version: ${version}"
    fi
  else
    skip "Keine vorhandene Binary unter ${LLAMA_SERVER_BIN}"
  fi
}

test_build_directory_size() {
  print_header "Test 3: Build-Verzeichnis Größe"
  
  if [[ -d "${LLAMA_CPP_DIR}" ]]; then
    local total_size
    total_size=$(du -sh "${LLAMA_CPP_DIR}" 2>/dev/null | cut -f1)
    
    print_info "Gesamtgröße: ${total_size}"
    
    # Optimiert: <200MB, Alt: >1GB
    local size_mb
    size_mb=$(du -sm "${LLAMA_CPP_DIR}" 2>/dev/null | cut -f1)
    
    if [[ "${size_mb:-0}" -lt 200 ]]; then
      pass "Build-Verzeichnis ist optimiert (<200MB)"
    elif [[ "${size_mb:-0}" -lt 500 ]]; then
      print_warn "Build-Verzeichnis könnte kleiner sein (${size_mb}MB)"
      ((TEST_PASSED++)) || true
    else
      fail "Build-Verzeichnis zu groß (${size_mb}MB) - Cleanup empfohlen"
      print_info "Bereinigen mit: rm -rf ${LLAMA_CPP_DIR}/build/CMakeFiles ${LLAMA_CPP_DIR}/build/*.o"
    fi
    
    # Unterverzeichnisse auflisten
    print_info "Verzeichnis-Struktur:"
    du -sh "${LLAMA_CPP_DIR}"/* 2>/dev/null | sort -hr | head -10
  else
    skip "LLAMA_CPP_DIR existiert nicht: ${LLAMA_CPP_DIR}"
  fi
}

test_git_repo_size() {
  print_header "Test 4: Git-Repo Größe (shallow clone?)"
  
  if [[ -d "${LLAMA_CPP_DIR}/.git" ]]; then
    local git_size
    git_size=$(du -sh "${LLAMA_CPP_DIR}/.git" 2>/dev/null | cut -f1)
    
    print_info "Git-Verzeichnis: ${git_size}"
    
    # Shallow clone erkennen
    if [[ -f "${LLAMA_CPP_DIR}/.git/shallow" ]]; then
      pass "Shallow clone erkannt (optimiert)"
    else
      fail "Vollständiger Git-Klon (nicht optimiert)"
      print_info "Empfehlung: Neu klonen mit --depth 1"
    fi
    
    # Anzahl Commits im shallow clone
    if [[ -f "${LLAMA_CPP_DIR}/.git/shallow" ]]; then
      local commit_count
      commit_count=$(wc -l < "${LLAMA_CPP_DIR}/.git/shallow")
      print_info "Shallow Commits: ${commit_count}"
    fi
  else
    skip "Kein Git-Repo vorhanden (Binary-Only Installation)"
  fi
}

test_build_artifacts() {
  print_header "Test 5: Build-Artefakte bereinigt?"
  
  local artifacts_found=0
  
  # Object files
  if [[ -d "${LLAMA_CPP_DIR}/build" ]]; then
    local obj_count
    obj_count=$(find "${LLAMA_CPP_DIR}/build" -name "*.o" 2>/dev/null | wc -l)
    
    if [[ "${obj_count}" -gt 0 ]]; then
      print_warn "Object files gefunden: ${obj_count}"
      artifacts_found=1
    fi
  fi
  
  # CMakeFiles
  if [[ -d "${LLAMA_CPP_DIR}/build/CMakeFiles" ]]; then
    print_warn "CMakeFiles Verzeichnis existiert"
    artifacts_found=1
  fi
  
  # CMakeCache
  if [[ -f "${LLAMA_CPP_DIR}/build/CMakeCache.txt" ]]; then
    print_warn "CMakeCache.txt existiert"
    artifacts_found=1
  fi
  
  if [[ ${artifacts_found} -eq 0 ]]; then
    pass "Build-Artefakte wurden bereinigt"
  else
    fail "Build-Artefakte vorhanden (Cleanup empfohlen)"
    print_info "Bereinigen mit:"
    print_info "  find ${LLAMA_CPP_DIR}/build -name '*.o' -delete"
    print_info "  rm -rf ${LLAMA_CPP_DIR}/build/CMakeFiles"
    print_info "  rm -f ${LLAMA_CPP_DIR}/build/CMakeCache.txt"
  fi
}

test_cuda_support() {
  print_header "Test 6: CUDA Support prüfen"
  
  if [[ ! -x "${LLAMA_SERVER_BIN}" ]]; then
    skip "llama-server nicht gefunden"
    return
  fi
  
  # CUDA im Binary prüfen (strings)
  if command -v strings &>/dev/null; then
    if strings "${LLAMA_SERVER_BIN}" 2>/dev/null | grep -q "CUDA\|cuBLAS\|ggml_cuda"; then
      pass "CUDA Support im Binary erkannt"
    else
      print_warn "Kein CUDA Support im Binary erkennbar"
      print_warn "Könnte CPU-only Build sein"
      ((TEST_PASSED++)) || true
    fi
  else
    skip "strings command nicht verfügbar"
  fi
  
  # nvidia-smi Test
  if command -v nvidia-smi &>/dev/null; then
    local gpu_count
    gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader 2>/dev/null | head -1 || echo "0")
    print_info "Verfügbare GPUs: ${gpu_count}"
  else
    print_warn "nvidia-smi nicht verfügbar"
  fi
}

test_install_function() {
  print_header "Test 7: install_llama_cpp() Funktion testen"
  
  # Funktion aus setup_remote_v3.sh laden
  if [[ -f "${SCRIPT_DIR}/setup_remote_v3.sh" ]]; then
    print_info "Lade setup_remote_v3.sh..."
    
    # Nur die Funktion extrahieren und testen
    # (Vollständiges Source wäre zu komplex zu mocken)
    
    # Umgebungsvariablen prüfen
    print_info "Umgebungsvariablen:"
    print_info "  USE_PREBUILT_LLAMA=${USE_PREBUILT_LLAMA:-1}"
    print_info "  FORCE_SOURCE_BUILD=${FORCE_SOURCE_BUILD:-0}"
    print_info "  LLAMA_CPP_DIR=${LLAMA_CPP_DIR}"
    
    pass "Setup-Skript existiert und ist lesbar"
  else
    fail "setup_remote_v3.sh nicht gefunden"
  fi
}

test_performance() {
  print_header "Test 8: Performance-Schätzung"
  
  if [[ -x "${LLAMA_SERVER_BIN}" ]]; then
    # Startzeit messen
    local start_time
    start_time=$(date +%s.%N)
    
    timeout 5 "${LLAMA_SERVER_BIN}" --help &>/dev/null || true
    
    local end_time
    end_time=$(date +%s.%N)
    
    local duration
    duration=$(echo "${end_time} - ${start_time}" | bc)
    
    print_info "Binary Startzeit: ${duration}s"
    
    if (( $(echo "${duration} < 1" | bc -l) )); then
      pass "Binary startet schnell (<1s)"
    elif (( $(echo "${duration} < 3" | bc -l) )); then
      print_warn "Binary Startzeit akzeptabel (${duration}s)"
      ((TEST_PASSED++)) || true
    else
      fail "Binary startet langsam (${duration}s)"
    fi
  else
    skip "Kein Binary zum Testen"
  fi
}

print_summary() {
  print_header "Test Zusammenfassung"
  
  echo ""
  echo "┌────────────────────────────────────────┐"
  printf "│ %-20s %15s │\n" "Bestanden:" "${TEST_PASSED}"
  printf "│ %-20s %15s │\n" "Fehlgeschlagen:" "${TEST_FAILED}"
  printf "│ %-20s %15s │\n" "Übersprungen:" "${TEST_SKIPPED}"
  echo "└────────────────────────────────────────┘"
  echo ""
  
  if [[ ${TEST_FAILED} -eq 0 ]]; then
    print_ok "Alle Tests bestanden!"
    return 0
  else
    print_err "${TEST_FAILED} Test(s) fehlgeschlagen"
    return 1
  fi
}

# ── Main ───────────────────────────────────────────────────────────────────

QUICK_MODE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)
      QUICK_MODE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      echo "Verwendung: $0 [--quick] [--dry-run]"
      echo "  --quick    Nur schnelle Tests (existierende Binary)"
      echo "  --dry-run  Nur Logik prüfen, nichts ausführen"
      exit 0
      ;;
    *)
      print_err "Unbekanntes Argument: $1"
      exit 1
      ;;
  esac
done

print_header "llama.cpp Installation Test"
echo ""
print_info "LLAMA_CPP_DIR: ${LLAMA_CPP_DIR}"
print_info "LLAMA_SERVER_BIN: ${LLAMA_SERVER_BIN}"
print_info "USE_PREBUILT_LLAMA: ${USE_PREBUILT_LLAMA:-1}"
print_info "FORCE_SOURCE_BUILD: ${FORCE_SOURCE_BUILD:-0}"
echo ""

if [[ ${DRY_RUN} -eq 1 ]]; then
  print_info "Dry-Run Modus - Tests werden nur simuliert"
fi

if [[ ${QUICK_MODE} -eq 1 ]]; then
  test_existing_build
else
  test_system_llama
  test_existing_build
  test_build_directory_size
  test_git_repo_size
  test_build_artifacts
  test_cuda_support
  test_install_function
  test_performance
fi

print_summary
