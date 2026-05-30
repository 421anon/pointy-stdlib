#!/usr/bin/env bash
# merge-extras: merge multiple extras derivation trees into one.
# Duplicate child-file keys within the same directory are a build error.
# Usage: merge-extras.sh <jq> <out> <src1> [<src2> ...]
set -euo pipefail

JQ="$1"
OUT="$2"
shift 2

mkdir -p "$OUT"

for src in "$@"; do
    [ -d "$src" ] || continue
    while IFS= read -r -d '' meta; do
        rel="${meta#"$src"/}"
        out_meta="$OUT/$rel"
        out_dir="${out_meta%/*}"
        mkdir -p "$out_dir"

        if [ ! -f "$out_meta" ]; then
            cp "$meta" "$out_meta"
        else
            # Check for duplicate keys before merging.
            dups="$(
                "$JQ" -n \
                    --slurpfile a "$out_meta" \
                    --slurpfile b "$meta" \
                    '($a[0] | keys) as $ak | ($b[0] | keys) as $bk |
                     [$ak[] | select(. as $k | $bk | contains([$k]))] | join(", ")'
            )"
            if [ -n "$dups" ] && [ "$dups" != '""' ] && [ "$dups" != "" ]; then
                printf 'Error: duplicate extras keys in %s: %s\n' "$out_meta" "$dups" >&2
                exit 1
            fi
            tmp="$(mktemp)"
            "$JQ" -n \
                --slurpfile a "$out_meta" \
                --slurpfile b "$meta" \
                '$a[0] * $b[0]' > "$tmp"
            mv "$tmp" "$out_meta"
        fi
    done < <(find "$src" -name 'meta.json' -print0)
done
