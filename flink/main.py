"""
PyFlink entry point for Managed Service for Apache Flink.

It does almost nothing itself: it reads the Flink SQL file
(`excursion_detector.sql`), substitutes the deploy-time placeholders from the
application's runtime properties (set by Terraform), and executes each
statement on the Table environment. All the actual logic lives in the SQL; the
Python is just a loader.
"""
import os
from string import Template

from pyflink.table import EnvironmentSettings, TableEnvironment

APPLICATION_PROPERTIES_FILE = "/etc/flink/application_properties.json"


def _runtime_props() -> dict:
    """Read Managed-Flink runtime properties (group 'detector')."""
    import json

    if not os.path.exists(APPLICATION_PROPERTIES_FILE):
        # Local run fallback: take from env vars.
        return {
            "input_stream": os.environ["INPUT_STREAM"],
            "output_stream": os.environ["OUTPUT_STREAM"],
            "region": os.environ.get("AWS_REGION", "eu-central-1"),
            "window": os.environ.get("WINDOW_MINUTES", "5"),
            "battery_window": os.environ.get("BATTERY_WINDOW_MINUTES", "1"),
        }
    with open(APPLICATION_PROPERTIES_FILE) as f:
        groups = json.load(f)
    for g in groups:
        if g.get("PropertyGroupId") == "detector":
            return g["PropertyMap"]
    raise RuntimeError("property group 'detector' not found")


def main() -> None:
    props = _runtime_props()

    env = TableEnvironment.create(EnvironmentSettings.in_streaming_mode())

    sql_path = os.path.join(os.path.dirname(__file__), "excursion_detector.sql")
    with open(sql_path) as f:
        # safe_substitute (not substitute): our real ${...} placeholders are all
        # present in props and resolve, while any other '$' in the SQL — e.g. a
        # ${...} appearing inside a COMMENT as documentation — is left untouched
        # instead of raising ValueError('Invalid placeholder').
        rendered = Template(f.read()).safe_substitute(props)

    # Strip SQL line comments BEFORE splitting. The .sql file documents each
    # statement with leading `-- ...` comment blocks; if those are left in, two
    # things break: (a) a chunk that is ONLY comments (e.g. the trailing text
    # after the last ';') is handed to the parser, which hits <EOF> expecting a
    # statement and raises SqlParserEOFException; and (b) `startswith("INSERT")`
    # fails because the string starts with '--', so INSERTs get misrouted out of
    # the statement set. Removing `--` line comments first avoids both.
    def _strip_comments(text: str) -> str:
        lines = []
        for line in text.splitlines():
            stripped = line.lstrip()
            if stripped.startswith("--"):
                continue  # whole-line comment
            lines.append(line)
        return "\n".join(lines)

    sql_no_comments = _strip_comments(rendered)

    # Split on ';' into individual statements (no ';' appears inside a statement
    # here), dropping any empty/whitespace-only fragment.
    statements = [s.strip() for s in sql_no_comments.split(";") if s.strip()]

    # DDL (CREATE TABLE ...) just registers tables — run each immediately.
    # INSERT statements must be bundled into ONE statement set so they execute
    # as a SINGLE Flink job that shares the one Kinesis source. Running each
    # INSERT via execute_sql() instead would submit multiple independent jobs,
    # which Managed Flink rejects (the app rolls back to READY instead of
    # reaching RUNNING).
    stmt_set = env.create_statement_set()
    has_inserts = False
    for stmt in statements:
        if stmt.upper().lstrip().startswith("INSERT"):
            stmt_set.add_insert_sql(stmt)
            has_inserts = True
        else:
            env.execute_sql(stmt)

    if has_inserts:
        stmt_set.execute()


if __name__ == "__main__":
    main()
