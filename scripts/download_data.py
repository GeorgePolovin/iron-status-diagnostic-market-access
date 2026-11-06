"""Download the public source files used by this project into data/raw/.

All three sources are public and free to use:
    NHANES 2017-March 2020 pre-pandemic (CDC/NCHS)  - laboratory + questionnaire files
    MEPS 2023 (AHRQ)                                - full-year consolidated + medical conditions
    Synthea sample data, April 2020 (MITRE)         - fully synthetic longitudinal EHR records

Files that already exist are skipped, so the script is safe to re-run.
Usage (from the repository root):
    python scripts/download_data.py
"""

from pathlib import Path
from urllib.request import urlretrieve
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"

NHANES_BASE = "https://wwwn.cdc.gov/Nchs/Data/Nhanes/Public/2017/DataFiles/"
NHANES_FILES = [
    "P_DEMO.XPT",    # demographics + survey design
    "P_FERTIN.XPT",  # ferritin
    "P_CBC.XPT",     # complete blood count (hemoglobin)
    "P_HSCRP.XPT",   # high-sensitivity C-reactive protein (inflammation)
    "P_FETIB.XPT",   # serum iron, TIBC, transferrin saturation
    "P_RHQ.XPT",     # reproductive health (menstrual periods)
    "P_PAQ.XPT",     # physical activity
    "P_MCQ.XPT",     # medical conditions (heart failure)
    "P_KIQ_U.XPT",   # kidney conditions
    "P_HIQ.XPT",     # health insurance
    "P_HUQ.XPT",     # health-care access and utilization
]

MEPS_FILES = {
    "h251": "https://meps.ahrq.gov/mepsweb/data_files/pufs/h251/h251xlsx.zip",
    "h249": "https://meps.ahrq.gov/mepsweb/data_files/pufs/h249/h249xlsx.zip",
}

SYNTHEA_URL = (
    "https://synthetichealth.github.io/synthea-sample-data/downloads/"
    "synthea_sample_data_csv_apr2020.zip"
)


def fetch(url: str, destination: Path) -> None:
    if destination.exists():
        print(f"exists   {destination.relative_to(ROOT)}")
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    print(f"download {url}")
    urlretrieve(url, destination)


def unzip(archive: Path, target: Path, marker: str) -> None:
    if (target / marker).exists():
        return
    target.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as z:
        z.extractall(target)


def main() -> None:
    for name in NHANES_FILES:
        fetch(NHANES_BASE + name, RAW / "nhanes" / name)

    for key, url in MEPS_FILES.items():
        archive = RAW / "meps" / f"{key}xlsx.zip"
        fetch(url, archive)
        unzip(archive, RAW / "meps" / key, f"{key}.xlsx")

    archive = RAW / "synthea" / "synthea_sample_data_csv_apr2020.zip"
    fetch(SYNTHEA_URL, archive)
    unzip(archive, RAW / "synthea", "csv/patients.csv")
    print("All public source files are in data/raw/.")


if __name__ == "__main__":
    main()
