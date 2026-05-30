#!/usr/bin/env bash
# csv-extras: scan baseDrv for CSV/TSV files; emit meta.json per directory.
# Usage: csv-extras.sh <duckdb> <jq> <base> <out>
set -euo pipefail

DUCKDB="$1"
JQ="$2"
BASE="$3"
OUT="$4"

mkdir -p "$OUT"

while IFS= read -r -d '' f; do
    rel="${f#"$BASE"/}"
    dir="${rel%/*}"; [ "$dir" = "$rel" ] && dir=""
    filename="${rel##*/}"
    lname="$(printf '%s' "$filename" | tr '[:upper:]' '[:lower:]')"

    case "$lname" in
        *.tsv) sep=$'\t'; delim_json="\\t" ;;
        *.csv) sep=",";   delim_json="," ;;
        *)     continue ;;
    esac

    # Escape single-quotes for embedding in SQL string literals.
    f_esc="${f//\'/\'\'}"
    sep_esc="${sep//\'/\'\'}"

    # One duckdb query: sniff types + check nullability via UNPIVOT.
    result=$(
        "$DUCKDB" :memory: -json 2>/dev/null <<SQL || true
PRAGMA disable_progress_bar;
WITH
  sniff AS (
    SELECT * FROM sniff_csv('${f_esc}', sep='${sep_esc}') LIMIT 1
  ),
  indexed AS (
    SELECT generate_subscripts(columns, 1) AS i, columns[generate_subscripts(columns, 1)] AS c
    FROM sniff
  ),
  nulls AS (
    SELECT column_name, null_percentage > 0 AS has_null
    FROM (SUMMARIZE SELECT * FROM read_csv('${f_esc}', sep='${sep_esc}', all_varchar=true, null_padding=true))
  )
SELECT to_json(list(
  json_object(
    'type', CASE
      WHEN c.type IN (
        'BIGINT','INTEGER','SMALLINT','TINYINT','HUGEINT',
        'UBIGINT','UINTEGER','USMALLINT','UTINYINT'
      ) THEN 'int'
      WHEN c.type IN ('DOUBLE','FLOAT','REAL')
        OR c.type LIKE 'DECIMAL%'
        OR c.type LIKE 'NUMERIC%'
      THEN 'float'
      ELSE 'string'
    END,
    'nullable', coalesce((SELECT has_null FROM nulls WHERE column_name = c.name), false)
  ) ORDER BY i
)) AS columns
FROM indexed;
SQL
    )

    [ -z "$result" ] && { printf 'Warning: no result for %s\n' "$f" >&2; continue; }

    columns_json=$(
        printf '%s' "$result" \
            | "$JQ" -c '.[0].columns | if type == "string" then fromjson else . end // []'
    )

    entry=$(
        "$JQ" -cn \
            --arg d "$delim_json" \
            --argjson c "$columns_json" \
            '{"delimiter":$d,"hasHeader":true,"columns":$c}'
    )

    target="$OUT${dir:+/$dir}"
    mkdir -p "$target"
    meta="$target/meta.json"

    if [ -f "$meta" ]; then
        tmp="$(mktemp)"
        "$JQ" --arg k "$filename" --argjson v "$entry" '. + {($k): $v}' "$meta" > "$tmp"
        mv "$tmp" "$meta"
    else
        "$JQ" -n --arg k "$filename" --argjson v "$entry" '{($k): $v}' > "$meta"
    fi
done < <(find -L "$BASE" -type f \( -iname '*.csv' -o -iname '*.tsv' \) -print0)
