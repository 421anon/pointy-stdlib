#!/usr/bin/env bash
# fastq-extras: scan baseDrv for FASTQ files; emit meta.json per directory.
# Usage: fastq-extras.sh <base> <out>
set -euo pipefail

BASE="$1"
OUT="$2"

mkdir -p "$OUT"

# Per-directory JSON accumulator (bash associative array).
declare -A dir_entries

while IFS= read -r -d '' f; do
    rel="${f#"$BASE"/}"
    dir="${rel%/*}"; [ "$dir" = "$rel" ] && dir="ROOT"
    filename="${rel##*/}"
    lname="$(printf '%s' "$filename" | tr '[:upper:]' '[:lower:]')"

    case "$lname" in
        *.gz) lines="$(zcat "$f" | wc -l)" ;;
        *)    lines="$(wc -l < "$f")" ;;
    esac

    if [ $(( lines % 4 )) -ne 0 ]; then
        printf 'Error: %s has %d lines, not divisible by 4\n' "$f" "$lines" >&2
        exit 1
    fi

    reads=$(( lines / 4 ))

    entry="\"$(printf '%s' "$filename" | sed 's/["\\]/\\&/g')\":{\"readCount\":${reads}}"

    if [ -n "${dir_entries["$dir"]+_}" ]; then
        dir_entries["$dir"]="${dir_entries["$dir"]},${entry}"
    else
        dir_entries["$dir"]="${entry}"
    fi
done < <(find -L "$BASE" -type f \( -iname '*.fastq' -o -iname '*.fq' -o -iname '*.fastq.gz' -o -iname '*.fq.gz' \) -print0)

for dir in "${!dir_entries[@]}"; do
    if [ "$dir" = "ROOT" ]; then
        target="$OUT"
    else
        target="$OUT/$dir"
    fi
    mkdir -p "$target"
    printf '{%s}\n' "${dir_entries["$dir"]}" > "$target/meta.json"
done
