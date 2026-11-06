"""Load the NHANES 2017-March 2020 pre-pandemic SAS transport files into DuckDB.

Each file is loaded unchanged as nhanes.<name>_raw (one row per participant,
keyed by SEQN). Cleaning and clinical definitions happen downstream in SQL.
Called by run_pipeline.py; can also be run on its own from the repo root.
"""

from pathlib import Path

import duckdb
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw" / "nhanes"

TABLES = {
    "demo_raw": "P_DEMO.XPT",
    "ferritin_raw": "P_FERTIN.XPT",
    "cbc_raw": "P_CBC.XPT",
    "hscrp_raw": "P_HSCRP.XPT",
    "fetib_raw": "P_FETIB.XPT",
    "rhq_raw": "P_RHQ.XPT",
    "paq_raw": "P_PAQ.XPT",
    "mcq_raw": "P_MCQ.XPT",
    "kiq_raw": "P_KIQ_U.XPT",
    "hiq_raw": "P_HIQ.XPT",
    "huq_raw": "P_HUQ.XPT",
}


def load(con: duckdb.DuckDBPyConnection) -> None:
    con.execute("CREATE SCHEMA IF NOT EXISTS nhanes")
    for table, filename in TABLES.items():
        df = pd.read_sas(RAW / filename, format="xport", encoding="utf-8")
        # pandas decodes SAS zero as ~5e-79; restore exact zeros.
        num = df.select_dtypes("number").columns
        df[num] = df[num].mask(df[num].abs() < 1e-30, 0.0)
        if df["SEQN"].isna().any() or df["SEQN"].duplicated().any():
            raise ValueError(f"{filename}: SEQN must be present and unique")
        con.register("df_import", df)
        con.execute(f"CREATE OR REPLACE TABLE nhanes.{table} AS SELECT * FROM df_import")
        con.unregister("df_import")
        print(f"  nhanes.{table:<13} {len(df):>7,} rows  <- {filename}")


if __name__ == "__main__":
    with duckdb.connect(str(ROOT / "database" / "market_access.duckdb")) as con:
        load(con)
