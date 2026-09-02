import argparse
import json
import os
import subprocess
import sys
import time

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS review_sessions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_root    VARCHAR NOT NULL,
    branch_name     VARCHAR,
    rev1            VARCHAR,
    rev2            VARCHAR,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS review_comments (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    comment_scope   VARCHAR NOT NULL CHECK (comment_scope IN ('review', 'file', 'line')),
    file_path       VARCHAR,
    line_start      INTEGER,
    line_end        INTEGER,
    side            VARCHAR CHECK (side IN ('old', 'new')),
    comment_type    VARCHAR NOT NULL CHECK (comment_type IN ('note', 'suggestion', 'issue', 'praise')),
    content         VARCHAR NOT NULL,
    author          VARCHAR NOT NULL DEFAULT 'user',
    lifecycle_state VARCHAR NOT NULL DEFAULT 'submitted',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_comments_file ON review_comments(file_path);
""".strip()

WRITE_CONTENTION_MAX_RETRIES = 3
WRITE_CONTENTION_BACKOFF_SECONDS = 0.05


class DuckDBError(Exception):
    pass


class NoStoragePathError(Exception):
    pass


def _escape_literal(value):
    return "'" + value.replace("'", "''") + "'"


def _literal(value):
    if value is None:
        return "NULL"
    if isinstance(value, int):
        return str(value)
    return _escape_literal(value)


def _is_lock_contention(stderr):
    return stderr is not None and "Conflicting lock is held" in stderr


def _run_duckdb(db_path, sql, readonly=False, retry=False):
    cmd = ["duckdb", db_path, "-json"]
    if readonly:
        cmd.append("-readonly")
    cmd += ["-c", sql]

    retries_left = WRITE_CONTENTION_MAX_RETRIES if retry else 0

    while True:
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        except FileNotFoundError:
            raise DuckDBError("duckdb not found on PATH; install via your package manager (e.g. `brew install duckdb`)")

        if result.returncode == 0:
            stdout = result.stdout.strip()
            if not stdout:
                return []
            return json.loads(stdout)

        if retries_left > 0 and _is_lock_contention(result.stderr):
            retries_left -= 1
            time.sleep(WRITE_CONTENTION_BACKOFF_SECONDS)
            continue

        raise DuckDBError(result.stderr.strip() or "duckdb query failed with no error output")


def _git_output(args):
    result = subprocess.run(["git"] + args, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return None
    output = result.stdout.strip()
    return output or None


def _hash(s):
    h = 0
    for byte in s.encode("utf-8"):
        h = (h * 31 + byte) % 2147483647
    return format(h, "x")


def _sanitize_branch(branch):
    return "".join(c if (c.isalnum() or c in ("-", "_")) else "_" for c in branch)


def get_storage_path():
    git_root = _git_output(["rev-parse", "--show-toplevel"])
    if git_root is None:
        raise NoStoragePathError("not in a git repo (git rev-parse --show-toplevel failed)")

    branch = _git_output(["rev-parse", "--abbrev-ref", "HEAD"])
    if branch is None:
        raise NoStoragePathError("could not resolve current git branch (git rev-parse --abbrev-ref HEAD failed)")

    data_dir = os.path.expanduser("~/.local/share/nvim/review")
    project_hash = _hash(git_root)
    safe_branch = _sanitize_branch(branch)
    return os.path.join(data_dir, f"{project_hash}-{safe_branch}.duckdb")


def _ensure_schema_and_query(db_path, sql, readonly=False, retry=False):
    if readonly:
        # -readonly cannot create a not-yet-existing database file, so schema
        # bootstrap (which may need to create it) must run in a separate,
        # non-readonly call first.
        _run_duckdb(db_path, SCHEMA_SQL, readonly=False, retry=retry)
        return _run_duckdb(db_path, sql, readonly=True, retry=False)

    combined = SCHEMA_SQL + "\n" + sql
    return _run_duckdb(db_path, combined, readonly=False, retry=retry)


def cmd_read(args):
    try:
        db_path = get_storage_path()
    except NoStoragePathError as e:
        print(json.dumps({"status": "error", "reason": str(e), "stage": "read"}))
        sys.exit(1)

    conditions = []
    if args.file:
        conditions.append(f"file_path = {_escape_literal(args.file)}")
    if args.author:
        conditions.append(f"author = {_escape_literal(args.author)}")

    where = f" WHERE {' AND '.join(conditions)}" if conditions else ""
    sql = f"SELECT * FROM review_comments{where} ORDER BY file_path, line_start;"

    try:
        rows = _ensure_schema_and_query(db_path, sql, readonly=True, retry=False)
    except DuckDBError as e:
        print(json.dumps({"status": "error", "reason": str(e), "stage": "read"}))
        sys.exit(1)

    print(json.dumps({"status": "success", "comments": rows}))


def cmd_add(args):
    try:
        db_path = get_storage_path()
    except NoStoragePathError as e:
        print(json.dumps({"status": "error", "reason": str(e), "stage": "add"}))
        sys.exit(1)

    scope = "file" if args.line is None else "line"
    line_end = args.line_end if (args.line_end is not None and args.line_end != args.line) else None
    side = args.side or "new"

    sql = f"""INSERT INTO review_comments (comment_scope, file_path, line_start, line_end, side, comment_type, content, author)
VALUES ({_literal(scope)}, {_literal(args.file)}, {_literal(args.line) if scope == "line" else "NULL"}, {_literal(line_end)}, {_literal(side) if scope == "line" else "NULL"}, {_literal(args.type)}, {_literal(args.content)}, {_literal(args.author)})
RETURNING id, created_at;"""

    try:
        rows = _ensure_schema_and_query(db_path, sql, readonly=False, retry=True)
    except DuckDBError as e:
        print(json.dumps({"status": "error", "reason": str(e), "stage": "add"}))
        sys.exit(1)

    row = rows[0]
    print(json.dumps({"status": "success", "id": row["id"], "created_at": row["created_at"]}))


def main():
    parser = argparse.ArgumentParser(description="Read and add review.nvim code-review comments via the duckdb CLI")
    subparsers = parser.add_subparsers(dest="command", required=True)

    read_parser = subparsers.add_parser("read", help="Read comments from the current branch's review database")
    read_parser.add_argument("--file", type=str, default=None, help="Filter to comments on this file path")
    read_parser.add_argument("--author", type=str, default=None, help="Filter to comments by this author")
    read_parser.set_defaults(func=cmd_read)

    add_parser = subparsers.add_parser("add", help="Add a comment to the current branch's review database")
    add_parser.add_argument("--file", type=str, required=True, help="File path the comment is about")
    add_parser.add_argument("--content", type=str, required=True, help="Comment text")
    add_parser.add_argument("--author", type=str, required=True, help="Author, e.g. agent:claude-code")
    add_parser.add_argument("--type", type=str, required=True, choices=["note", "suggestion", "issue", "praise"])
    add_parser.add_argument("--line", type=int, default=None, help="Start line (omit for a file-scope comment)")
    add_parser.add_argument("--line-end", type=int, default=None, help="End line, for a line-range comment")
    add_parser.add_argument("--side", type=str, default=None, choices=["old", "new"], help="Diff side (line-scope only; defaults to 'new')")
    add_parser.set_defaults(func=cmd_add)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
