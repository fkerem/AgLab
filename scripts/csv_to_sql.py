#!/usr/bin/env python3
"""
Generic CSV -> ONE bulk INSERT (optionally UPSERT) SQL generator for Postgres.

Examples:

1) Simple bulk insert:
  python csv_to_sql.py input.csv \
    --table soil_moisture \
    --cols ts,device_id,depth_cm,vwc,ec_us_cm \
    --text-cols ts,device_id \
    --int-cols depth_cm,ec_us_cm \
    --numeric-cols vwc \
    > soil_moisture_bulk.sql

2) Bulk upsert:
  python csv_to_sql.py input.csv \
    --table soil_moisture \
    --cols ts,device_id,depth_cm,vwc,ec_us_cm \
    --text-cols ts,device_id \
    --int-cols depth_cm,ec_us_cm \
    --numeric-cols vwc \
    --conflict-cols ts,device_id,depth_cm \
    --update-cols vwc,ec_us_cm \
    > soil_moisture_upsert.sql
"""

import argparse
import csv
import sys
from pathlib import Path
from typing import Dict, Optional, Set


def sql_quote(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def parse_csv_list(s: str) -> list[str]:
    return [x.strip() for x in s.split(",") if x.strip()]


def convert_value(col: str, raw: str, types: Dict[str, str]) -> str:
    """
    Convert a CSV string to an SQL literal based on declared type.
    types[col] in {"text","int","numeric"}; default is text.
    """
    val = (raw or "").strip()
    if val == "":
        return "NULL"

    t = types.get(col, "text")
    if t == "text":
        return sql_quote(val)
    if t == "int":
        try:
            return str(int(val))
        except ValueError:
            raise ValueError(f"Column '{col}' expected int but got '{val}'")
    if t == "numeric":
        try:
            float(val)  # validate
            return val   # keep original formatting
        except ValueError:
            raise ValueError(f"Column '{col}' expected numeric but got '{val}'")

    raise ValueError(f"Unknown type '{t}' for column '{col}'")


def build_types(cols: list[str], text_cols: Set[str], int_cols: Set[str], numeric_cols: Set[str]) -> Dict[str, str]:
    types: Dict[str, str] = {}
    for c in cols:
        if c in int_cols:
            types[c] = "int"
        elif c in numeric_cols:
            types[c] = "numeric"
        elif c in text_cols:
            types[c] = "text"
        else:
            # default to text if not specified
            types[c] = "text"
    return types


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("csv_path", help="Input CSV file path")
    ap.add_argument("--table", required=True, help="Target table name, e.g., soil_moisture")
    ap.add_argument("--cols", required=True, help="Comma-separated column list to insert, e.g., ts,device_id,vwc")
    ap.add_argument("--text-cols", default="", help="Comma-separated columns treated as TEXT (quoted)")
    ap.add_argument("--int-cols", default="", help="Comma-separated columns treated as INTEGER")
    ap.add_argument("--numeric-cols", default="", help="Comma-separated columns treated as NUMERIC (unquoted)")
    ap.add_argument("--conflict-cols", default="", help="Comma-separated conflict columns for ON CONFLICT (...)")
    ap.add_argument("--update-cols", default="", help="Comma-separated columns to update on conflict")
    ap.add_argument("--skip-bad-rows", action="store_true", help="Skip rows that fail type conversion instead of erroring")
    args = ap.parse_args()

    cols = parse_csv_list(args.cols)
    if not cols:
        print("--cols cannot be empty", file=sys.stderr)
        return 2

    text_cols = set(parse_csv_list(args.text_cols))
    int_cols = set(parse_csv_list(args.int_cols))
    numeric_cols = set(parse_csv_list(args.numeric_cols))
    conflict_cols = parse_csv_list(args.conflict_cols)
    update_cols = parse_csv_list(args.update_cols)

    # Basic validation
    overlaps = (text_cols & int_cols) | (text_cols & numeric_cols) | (int_cols & numeric_cols)
    if overlaps:
        print(f"Columns listed in multiple type sets: {sorted(overlaps)}", file=sys.stderr)
        return 2

    if (conflict_cols and not update_cols) or (update_cols and not conflict_cols):
        print("If using upsert, you must provide BOTH --conflict-cols and --update-cols.", file=sys.stderr)
        return 2

    types = build_types(cols, text_cols, int_cols, numeric_cols)

    in_path = Path(args.csv_path)
    tuples_sql: list[str] = []
    skipped = 0

    with in_path.open("r", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)

        missing = [c for c in cols if c not in (reader.fieldnames or [])]
        if missing:
            print(f"Missing expected columns in CSV header: {missing}", file=sys.stderr)
            return 2

        for row in reader:
            try:
                values = [convert_value(c, row.get(c, ""), types) for c in cols]
                tuples_sql.append("(" + ", ".join(values) + ")")
            except Exception as e:
                if args.skip_bad_rows:
                    skipped += 1
                    continue
                raise

    if not tuples_sql:
        print(f"-- No valid rows found in {in_path.name} (skipped={skipped})")
        return 0

    cols_sql = ", ".join(cols)
    print(f"INSERT INTO {args.table} ({cols_sql}) VALUES")
    for i, tup in enumerate(tuples_sql):
        end = "," if i < len(tuples_sql) - 1 else ""
        print(f"  {tup}{end}")

    # Optional UPSERT
    if conflict_cols:
        conflict_sql = ", ".join(conflict_cols)
        updates = ", ".join([f"{c} = EXCLUDED.{c}" for c in update_cols])
        print(f"ON CONFLICT ({conflict_sql}) DO UPDATE SET {updates};")
    else:
        print(";")

    if skipped:
        print(f"-- Skipped {skipped} bad row(s) due to conversion errors.", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())