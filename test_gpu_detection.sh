#!/bin/bash
compute_cap_raw=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1)
echo "Raw compute capability: '$compute_cap_raw'"
compute_cap=$(echo "$compute_cap_raw" | tr -d '.')
echo "Processed compute capability: '$compute_cap'"
echo "Detected GPU compute capability: $compute_cap_raw -> sm_$compute_cap"

case "$compute_cap" in
  35|37) echo "Kepler (GK104, GK110)" ;;
  50|52|53) echo "Maxwell (GM107, GM200)" ;;
  60|61|62) echo "Pascal (GP100, GP102, GP104)" ;;
  70|72|75) echo "Volta (GV100) & Turing (TU102, TU104, TU106)" ;;
  80|86|89) 
    if [[ "$compute_cap" == "80" ]]; then
      echo "Ampere (GA100, GA102, GA104) - sm_80"
    elif [[ "$compute_cap" == "86" ]]; then
      echo "Ampere (RTX 3050, RTX 3060) - sm_86"
    elif [[ "$compute_cap" == "89" ]]; then
      echo "Ada Lovelace (AD102, AD104) - sm_89"
    fi
    ;;
  90) echo "Hopper (GH100) - sm_90" ;;
  *) echo "Unknown compute capability $compute_cap" ;;
esac
