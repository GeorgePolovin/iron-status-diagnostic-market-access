"""Build the full analysis from public source files.

    python scripts/download_data.py   # once: fetch NHANES, MEPS, Synthea
    python run_pipeline.py            # rebuild database + all marts and exports
    python scripts/build_tfl.py       # tables, figures and listings
    python scripts/build_deck.py      # results presentation

Every SQL file is executed statement by statement against a fresh DuckDB
database. Any result column named *status containing REVIEW or FAIL stops
the build, so the QA checks embedded in the SQL act as assertions.
"""

from pathlib import Path
import os
import sys
import time

import duckdb

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "scripts"))
import import_nhanes  # noqa: E402

DB = ROOT / "database" / "market_access.duckdb"

STEPS = [
    "sql/00_setup/00_create_schemas.sql",
    "python:import_nhanes",
    "sql/nhanes/02_profile_nhanes.sql",
    "sql/nhanes/03_define_analysis_population.sql",
    "sql/nhanes/04_ferritin_unmet_need.sql",
    "sql/nhanes/04b_inflammation_iron_status_qc.sql",
    "sql/nhanes/05_low_ferritin_without_anemia.sql",
    "sql/nhanes/06_risk_segment_analysis.sql",
    "sql/nhanes/07_nhanes_validation_exports.sql",
    "sql/meps/01_import_meps.sql",
    "sql/meps/02_profile_meps.sql",
    "sql/meps/03_define_target_population.sql",
    "sql/meps/04_utilization_access.sql",
    "sql/meps/05_insurance_oop.sql",
    "sql/meps/06_meps_validation_exports.sql",
    "sql/synthea/01_import_synthea.sql",
    "sql/synthea/02_profile_synthea.sql",
    "sql/synthea/03_define_target_cohort.sql",
    "sql/synthea/04_provider_organization_opportunity.sql",
    "sql/synthea/05_payer_access_analysis.sql",
    "sql/synthea/06_utilization_pathway_analysis.sql",
    "sql/synthea/07_final_validation_exports.sql",
]


def check_status(path: str, rel) -> None:
    cols = [c for c in rel.columns if c.lower().endswith("status")]
    if not cols:
        return
    for row in rel.fetchall():
        for c in cols:
            v = row[rel.columns.index(c)]
            if isinstance(v, str) and v.upper().startswith(("REVIEW", "FAIL")):
                raise SystemExit(f"QA check failed in {path}: {c} = {v}\n{row}")


def run_sql(con, path: str) -> int:
    text = (ROOT / path).read_text()
    statements = con.extract_statements(text)
    for stmt in statements:
        rel = con.query(stmt.query)
        if rel is not None:
            check_status(path, rel)
    return len(statements)


def main() -> None:
    os.chdir(ROOT)  # SQL paths are relative to the repo root
    (ROOT / "outputs" / "marts").mkdir(parents=True, exist_ok=True)
    (ROOT / "outputs" / "qa").mkdir(parents=True, exist_ok=True)
    DB.parent.mkdir(exist_ok=True)
    for f in (DB, DB.with_suffix(".duckdb.wal")):
        f.unlink(missing_ok=True)
    with duckdb.connect(str(DB)) as con:
        for step in STEPS:
            t = time.time()
            if step.startswith("python:"):
                print(f"> {step}")
                import_nhanes.load(con)
                continue
            n = run_sql(con, step)
            print(f"> {step:<55} {n:>4} statements  {time.time() - t:5.1f}s")
    print("Pipeline complete: all embedded QA checks passed.")


if __name__ == "__main__":
    main()
