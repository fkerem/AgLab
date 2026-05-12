#!/usr/bin/env python3
"""Convert a CSV file into batched PostgreSQL INSERT statements.

The helper intentionally writes literal SQL so students can inspect the output
before loading it with psql or a graphical SQL client.
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path


NULL_TOKENS = {"", "null", "none", "na", "n/a"}


def quote_identifier(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def quote_value(value: str) -> str:
    if value.strip().lower() in NULL_TOKENS:
        return "NULL"
    return "'" + value.replace("'", "''") + "'"


def chunks(rows: list[list[str]], size: int):
    for index in range(0, len(rows), size):
        yield rows[index : index + size]


def render_insert(schema: str | None, table: str, headers: list[str], rows: list[list[str]], batch_size: int) -> str:
    table_name = quote_identifier(table)
    if schema:
        table_name = f"{quote_identifier(schema)}.{table_name}"

    columns = ", ".join(quote_identifier(header) for header in headers)
    statements: list[str] = []
    for batch in chunks(rows, batch_size):
        values = []
        for row in batch:
            values.append("(" + ", ".join(quote_value(value) for value in row) + ")")
        statements.append(f"INSERT INTO {table_name} ({columns}) VALUES\n" + ",\n".join(values) + ";")
    return "\n\n".join(statements) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Convert CSV data to PostgreSQL INSERT SQL.")
    parser.add_argument("csv_file", type=Path)
    parser.add_argument("--table", required=True, help="Destination table name.")
    parser.add_argument("--schema", help="Optional destination schema name.")
    parser.add_argument("--output", type=Path, help="Output SQL file. Defaults to stdout.")
    parser.add_argument("--batch-size", type=int, default=500)
    args = parser.parse_args()

    if args.batch_size < 1:
        parser.error("--batch-size must be at least 1")

    with args.csv_file.open(newline="", encoding="utf-8") as handle:
        reader = csv.reader(handle)
        try:
            headers = next(reader)
        except StopIteration:
            parser.error("CSV file is empty")
        rows = list(reader)

    if not headers or any(not header.strip() for header in headers):
        parser.error("CSV header row must contain non-empty column names")

    expected_width = len(headers)
    for line_number, row in enumerate(rows, start=2):
        if len(row) != expected_width:
            parser.error(f"row {line_number} has {len(row)} columns; expected {expected_width}")

    sql = render_insert(args.schema, args.table, headers, rows, args.batch_size)

    if args.output:
        args.output.write_text(sql, encoding="utf-8")
    else:
        sys.stdout.write(sql)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
