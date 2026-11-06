"""Build the Tables, Figures and Listings (TFL) package from the DuckDB marts.

Run after run_pipeline.py (from the repo root):
    python scripts/build_tfl.py

Outputs
    outputs/tables/T##_*.csv  + outputs/tables/tfl_tables.xlsx (one sheet per table)
    outputs/figures/F##_*.png/.svg
    outputs/listings/L##_*.csv
    outputs/tfl_index.csv     catalogue of every output, its source and population

NHANES headline estimates carry design-based 95% confidence intervals
(Taylor linearization with the released strata / PSUs, domain estimation
over the full lab sample). Every Python point estimate is asserted against
the SQL mart value, so the two layers cannot silently drift apart.
"""

from pathlib import Path
import sys

import duckdb
import numpy as np
import pandas as pd
from matplotlib.ticker import PercentFormatter
from matplotlib.lines import Line2D
from scipy import stats

sys.path.insert(0, str(Path(__file__).resolve().parent))
from chart_style import (CONTEXT, INDIGO, INK, MUTED, ORANGE, TEAL,  # noqa: E402
                         clean, finish, new_figure)

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "outputs"
TABLES, FIGS, LISTS = OUT / "tables", OUT / "figures", OUT / "listings"
NHANES_NOTE = ("Source: NHANES 2017-March 2020 pre-pandemic (CDC/NCHS), MEC exam weights. "
               "Ferritin <15 ng/mL = WHO depleted iron stores.")
MEPS_NOTE = "Source: MEPS 2023 full-year consolidated (HC-251) + medical conditions (HC-249), AHRQ; person weights."
SYN_NOTE = ("Source: Synthea sample data (April 2020), ~1,200 fully synthetic patients. "
            "Illustrates workflow logic only;\nnot real utilization. Organization names are pseudonyms.")

INDEX: list[dict] = []
SHEETS: dict[str, pd.DataFrame] = {}


# ---------------------------------------------------------------- helpers
def save_table(number, name, df, title, population, source):
    path = TABLES / f"{number}_{name}.csv"
    df.to_csv(path, index=False)
    SHEETS[number] = df
    INDEX.append(dict(output=number, type="Table", file=str(path.relative_to(ROOT)),
                      title=title, population=population, source=source))


def save_listing(number, name, df, title, population, source):
    path = LISTS / f"{number}_{name}.csv"
    df.to_csv(path, index=False)
    INDEX.append(dict(output=number, type="Listing", file=str(path.relative_to(ROOT)),
                      title=title, population=population, source=source))


def register_figure(number, name, title, population, source):
    INDEX.append(dict(output=number, type="Figure",
                      file=str((FIGS / f"{number}_{name}.png").relative_to(ROOT)),
                      title=title, population=population, source=source))


def survey_proportion(df, y, domain, weight="w", strata="strata", psu="psu"):
    """Weighted domain proportion with Taylor-linearized SE and t-based 95% CI."""
    d = df[[weight, strata, psu]].copy()
    dom = domain.astype(float).to_numpy()
    yy = np.nan_to_num(df[y].astype(float).to_numpy())
    w = d[weight].to_numpy() * dom
    total_w = w.sum()
    p = (w * yy).sum() / total_w
    d["z"] = w * (yy - p) / total_w
    psu_tot = d.groupby([strata, psu])["z"].sum().reset_index()
    var = 0.0
    for _, g in psu_tot.groupby(strata):
        n_h = len(g)
        if n_h > 1:
            var += n_h / (n_h - 1) * ((g["z"] - g["z"].mean()) ** 2).sum()
    dof = psu_tot[[strata, psu]].drop_duplicates().shape[0] - psu_tot[strata].nunique()
    se = np.sqrt(var)
    t = stats.t.ppf(0.975, dof)
    return 100 * p, 100 * se, 100 * max(p - t * se, 0), 100 * min(p + t * se, 1), int(dom.sum())


def wmedian(df, value="ferritin_ng_ml", weight="w"):
    d = df.sort_values(value)
    cw = d[weight].cumsum()
    return d[value].to_numpy()[np.searchsorted(cw.to_numpy(), cw.iloc[-1] / 2)]


def pct_axis(ax, axis="x", decimals=0):
    fmt = PercentFormatter(100, decimals=decimals)
    (ax.xaxis if axis == "x" else ax.yaxis).set_major_formatter(fmt)


# ---------------------------------------------------------------- NHANES
def nhanes(con):
    base = con.execute("""
        SELECT patient_id, mec_exam_weight AS w, variance_stratum AS strata,
               variance_psu AS psu, ferritin_ng_ml, hemoglobin_g_dl, sex, age_years,
               ferritin_lt15_flag, ferritin_lt30_sensitivity_flag,
               female_20_44_nonpregnant_flag, ferritin_lt15_without_anemia_flag,
               ferritin_lt30_without_anemia_sensitivity_flag, primary_iron_anemia_status
        FROM analytics.nhanes_early_iron_depletion_flags""").df()
    adult = con.execute("SELECT patient_id, adult_anemia_flag, uninsured_flag, "
                        "no_routine_place_flag FROM analytics.nhanes_segment_participants").df()
    base = base.merge(adult, on="patient_id", how="left")
    base["no_anemia_adult"] = (base.adult_anemia_flag == 0).astype(int)
    base["lt15_no_anemia_adult"] = ((base.ferritin_lt15_flag == 1) & (base.adult_anemia_flag == 0)).astype(int)
    member = con.execute("SELECT segment_order, segment_type, population_segment, patient_id "
                         "FROM analytics.nhanes_segment_membership").df()
    summary = con.execute("SELECT * FROM mart.nhanes_risk_segment_summary ORDER BY segment_order").df()

    # T01 disposition ------------------------------------------------------
    q = lambda s: con.execute(s).fetchone()[0]  # noqa: E731
    disp = pd.DataFrame([
        ("NHANES", "Participants in demographics file", q("SELECT COUNT(*) FROM nhanes.demo_raw")),
        ("NHANES", "With measured ferritin and hemoglobin (core lab population)",
         q("SELECT COUNT(*) FROM analytics.nhanes_core_analysis_population")),
        ("NHANES", "Adults 18+ in core lab population", q("SELECT COUNT(*) FROM analytics.nhanes_segment_participants")),
        ("NHANES", "Primary segment: non-pregnant women 20-44",
         q("SELECT COUNT(*) FROM analytics.nhanes_early_iron_depletion_flags WHERE female_20_44_nonpregnant_flag = 1")),
        ("MEPS", "Persons in 2023 full-year file", q("SELECT COUNT(*) FROM meps.hc251_person")),
        ("MEPS", "Adults 18+ with positive person weight", q("SELECT COUNT(*) FROM analytics.meps_person_flags")),
        ("Synthea", "Synthetic patients", q("SELECT COUNT(*) FROM synthea.patients")),
        ("Synthea", "Target cohort (anemia, pregnancy, kidney, heart-failure conditions)",
         q("SELECT COUNT(*) FROM analytics.synthea_target_cohort")),
    ], columns=["source", "population_step", "unweighted_n"])
    save_table("T01", "analysis_population_disposition", disp,
               "Analysis population disposition by data source", "All sources", "SQL analytics layer")

    # T02 segment prevalence with 95% CI ----------------------------------
    rows = []
    for seg in summary.itertuples():
        ids = set(member.loc[member.population_segment == seg.population_segment, "patient_id"])
        dom = base.patient_id.isin(ids)
        p15, se15, lo15, hi15, n = survey_proportion(base, "ferritin_lt15_flag", dom)
        p30, _, lo30, hi30, _ = survey_proportion(base, "ferritin_lt30_sensitivity_flag", dom)
        pna, _, lona, hina, _ = survey_proportion(base, "lt15_no_anemia_adult", dom)
        psh, _, losh, hish, _ = survey_proportion(base, "no_anemia_adult", dom & (base.ferritin_lt15_flag == 1))
        assert n == seg.unweighted_n, seg.population_segment
        assert abs(p15 - seg.weighted_ferritin_lt15_pct) < 0.006, (seg.population_segment, p15)
        rows.append(dict(
            segment_order=seg.segment_order, segment_type=seg.segment_type,
            population_segment=seg.population_segment, unweighted_n=n,
            weighted_population_millions=seg.weighted_population_millions,
            ferritin_lt15_pct=round(p15, 1), ferritin_lt15_ci95=f"{lo15:.1f}-{hi15:.1f}",
            ferritin_lt15_se=round(se15, 2), ferritin_lt15_millions=seg.weighted_ferritin_lt15_millions,
            ferritin_lt30_pct=round(p30, 1), ferritin_lt30_ci95=f"{lo30:.1f}-{hi30:.1f}",
            lt15_without_anemia_pct=round(pna, 1), lt15_without_anemia_ci95=f"{lona:.1f}-{hina:.1f}",
            pct_of_lt15_not_anemic=round(psh, 1), pct_of_lt15_not_anemic_ci95=f"{losh:.1f}-{hish:.1f}",
            anemia_pct=seg.weighted_anemia_pct,
            chronic_disease_iron_deficiency_pct=seg.weighted_chronic_disease_id_pct,
            uninsured_pct=seg.weighted_uninsured_pct,
            no_routine_place_of_care_pct=seg.weighted_no_routine_place_pct,
            below_poverty_pct=seg.weighted_below_poverty_pct,
            income_4x_poverty_plus_pct=seg.weighted_income_4x_poverty_plus_pct,
            reliability_note=("Relative SE > 30%: unreliable" if se15 / max(p15, 1e-9) > 0.30
                              else seg.sample_size_note),
            ci_lo15=lo15, ci_hi15=hi15))
    t02 = pd.DataFrame(rows)
    save_table("T02", "nhanes_iron_status_by_risk_segment", t02.drop(columns=["ci_lo15", "ci_hi15"]),
               "Low iron stores, anemia and access by risk segment (95% CI)",
               "NHANES adults 18+, segments overlap", "mart.nhanes_risk_segment_summary + design-based CIs")

    # T03 primary result: low ferritin without anemia ---------------------
    prim = base.female_20_44_nonpregnant_flag == 1
    stage = con.execute("SELECT * FROM mart.nhanes_iron_status_stage_distribution").df()
    lfwa = con.execute("SELECT * FROM mart.nhanes_low_ferritin_without_anemia_summary ORDER BY definition_order").df()
    p_a, se_a, lo_a, hi_a, n_a = survey_proportion(base, "ferritin_lt15_without_anemia_flag", prim)
    assert abs(p_a - lfwa.loc[0, "weighted_low_iron_without_anemia_population_pct"]) < 0.006
    lt15 = prim & (base.ferritin_lt15_flag == 1)
    base["_no_anemia"] = (base.hemoglobin_g_dl >= 12.0).astype(int)
    p_share, _, lo_s, hi_s, n_s = survey_proportion(base, "_no_anemia", lt15)
    t03 = lfwa.copy()
    t03.insert(len(t03.columns), "ci95_low_iron_without_anemia_pct", "")
    t03.loc[0, "ci95_low_iron_without_anemia_pct"] = f"{lo_a:.1f}-{hi_a:.1f}"
    t03.insert(len(t03.columns), "ci95_pct_of_low_iron_without_anemia", "")
    t03.loc[0, "ci95_pct_of_low_iron_without_anemia"] = f"{lo_s:.1f}-{hi_s:.1f}"
    save_table("T03", "nhanes_low_ferritin_without_anemia", t03,
               "Low ferritin without anemia: primary and sensitivity definitions",
               "NHANES non-pregnant women 20-44 (n=1,517)", "mart.nhanes_low_ferritin_without_anemia_summary")

    thr = con.execute("SELECT * FROM mart.nhanes_ferritin_threshold_by_segment "
                      "ORDER BY population_segment, threshold_order").df()
    save_table("T04", "nhanes_ferritin_threshold_sensitivity", thr,
               "Share below ferritin thresholds of 15, 30 and 50 ng/mL", "NHANES adults 18+",
               "mart.nhanes_ferritin_threshold_by_segment")
    infl = con.execute("SELECT * FROM mart.nhanes_ferritin_inflammation_sensitivity ORDER BY analysis_order").df()
    save_table("T05", "nhanes_inflammation_sensitivity", infl,
               "Inflammation (CRP) sensitivity of the low-ferritin estimate",
               "NHANES non-pregnant women 20-44", "mart.nhanes_ferritin_inflammation_sensitivity")

    # F01 stage distribution ----------------------------------------------
    order = ["Ferritin <15 + no anemia", "Ferritin <15 + anemia",
             "Ferritin >=15 + anemia", "Ferritin >=15 + no anemia"]
    st = stage.set_index("iron_status_stage").loc[order]
    fig, ax = new_figure((0.36, 0.22, 0.56, 0.56))
    clean(ax)
    colors = [TEAL, ORANGE, INDIGO, CONTEXT]
    y = np.arange(len(st))
    ax.barh(y, st.weighted_population_pct, color=colors, height=0.62)
    labels = ["Depleted stores, NOT anemic", "Depleted stores + anemia",
              "Anemia, ferritin >=15", "Neither"]
    ax.set_yticks(y, labels, fontsize=14)
    ax.invert_yaxis()
    for i, r in enumerate(st.itertuples()):
        inside = r.weighted_population_pct > 50
        ax.text(r.weighted_population_pct - 1 if inside else r.weighted_population_pct + 1, i,
                f"{r.weighted_population_pct:.1f}%  |  {r.weighted_population_millions:.1f}M women",
                va="center", ha="right" if inside else "left", fontsize=13, color=INK)
    ax.set_xlim(0, 100)
    pct_axis(ax)
    ax.set_xlabel("Weighted share of non-pregnant women 20-44")
    finish(fig, FIGS / "F01_iron_anemia_stage_distribution",
           f"{p_share:.0f}% of women with depleted iron are not anemic",
           f"{lfwa.loc[0, 'weighted_low_iron_without_anemia_population_millions']:.1f}M US women 20-44 have "
           f"ferritin <15 ng/mL with normal hemoglobin (95% CI of share: {lo_s:.0f}-{hi_s:.0f}%)",
           NHANES_NOTE + "\nAnemia = hemoglobin <12.0 g/dL (WHO). Hemoglobin-triggered workflows miss this group.",
           "F01")
    register_figure("F01", "iron_anemia_stage_distribution", "Iron/anemia stage distribution",
                    "NHANES non-pregnant women 20-44", "mart.nhanes_iron_status_stage_distribution")

    # F02 segment prevalence with CI --------------------------------------
    t = t02.sort_values("segment_order")
    fig, ax = new_figure((0.33, 0.17, 0.60, 0.64))
    clean(ax)
    y = np.arange(len(t))
    col = {"Reference": CONTEXT, "Priority segment": TEAL, "Comparison": CONTEXT,
           "Clinician-supervised": ORANGE}
    for i, r in enumerate(t.itertuples()):
        c = col[r.segment_type]
        ax.plot([r.ci_lo15, r.ci_hi15], [i, i], color=c, linewidth=2.5, solid_capstyle="round")
        ax.scatter([r.ferritin_lt15_pct], [i], s=90, color=c, zorder=3, edgecolor="white", linewidth=1.5)
        ax.text(r.ci_hi15 + 0.8, i, f"{r.ferritin_lt15_pct:.1f}%  (n={r.unweighted_n:,})",
                va="center", fontsize=12, color=INK)
    ax.set_yticks(y, t.population_segment, fontsize=13)
    ax.invert_yaxis()
    ax.set_xlim(0, 48)
    pct_axis(ax)
    ax.set_xlabel("Weighted % with ferritin <15 ng/mL (dot) and 95% CI (line)")
    handles = [Line2D([], [], marker="o", linestyle="", markersize=9, color=c, label=l)
               for l, c in [("Priority (consumer) segment", TEAL), ("Clinician-supervised", ORANGE),
                            ("Reference / comparison", CONTEXT)]]
    ax.legend(handles=handles, loc="lower right", frameon=False, fontsize=11.5)
    finish(fig, FIGS / "F02_low_ferritin_by_segment",
           "Depleted iron concentrates in women of reproductive age",
           "Menstruating, lower-income and pregnant women carry the highest prevalence; men are near 1%",
           NHANES_NOTE + "\nSegments overlap. Pregnant n=76 (wide CI). In CKD/heart failure, ferritin <15 understates "
           "deficiency (see T02 chronic-disease definition).", "F02")
    register_figure("F02", "low_ferritin_by_segment", "Ferritin <15 prevalence by segment with 95% CI",
                    "NHANES adults 18+", "T02")

    # F03 need vs access --------------------------------------------------
    fig, ax = new_figure((0.10, 0.17, 0.84, 0.62))
    clean(ax, "both")
    show = t[t.population_segment != "Highly active men 18+"]
    for r in show.itertuples():
        c = col[r.segment_type]
        ax.scatter(r.ferritin_lt15_pct, r.uninsured_pct, s=60 + r.weighted_population_millions * 5,
                   color=c, alpha=0.9, edgecolor="white", linewidth=2, zorder=3)
    # label offsets in points from each bubble centre: (dx, dy, ha)
    offsets = {"Lower-income women 18-49": (12, 0, "left"), "Menstruating women 18-49": (14, -28, "left"),
               "Non-pregnant women 18-49": (-14, 14, "right"), "Highly active women 18-49": (12, -4, "left"),
               "Pregnant women 20-44": (-12, 10, "right"), "All non-pregnant adults 18+": (20, 10, "left"),
               "Men 18+": (16, 6, "left"), "Adults with weak/failing kidneys": (12, 2, "left"),
               "Adults with heart failure": (12, 0, "left")}
    for r in show.itertuples():
        dx, dy, ha = offsets[r.population_segment]
        ax.annotate(r.population_segment, (r.ferritin_lt15_pct, r.uninsured_pct), xytext=(dx, dy),
                    textcoords="offset points", fontsize=11.5, color=INK, ha=ha, va="center")
    ax.axvline(t.loc[t.population_segment == "All non-pregnant adults 18+", "ferritin_lt15_pct"].iloc[0],
               color=MUTED, linestyle="--", linewidth=1)
    ax.axhline(t.loc[t.population_segment == "All non-pregnant adults 18+", "uninsured_pct"].iloc[0],
               color=MUTED, linestyle="--", linewidth=1)
    ax.text(26.5, 28.3, "High need +\nlimited access", fontsize=12, color=MUTED, ha="right", va="top")
    ax.set_xlim(0, 27)
    ax.set_ylim(0, 30)
    ax.legend(handles=[Line2D([], [], marker="o", linestyle="", markersize=9, color=c, label=l)
                       for l, c in [("Priority (consumer) segment", TEAL), ("Clinician-supervised", ORANGE),
                                    ("Reference", CONTEXT)]],
              loc="upper left", frameon=False, fontsize=11.5)
    pct_axis(ax)
    pct_axis(ax, "y")
    ax.set_xlabel("Clinical need: weighted % with ferritin <15 ng/mL")
    ax.set_ylabel("Access gap: % uninsured")
    finish(fig, FIGS / "F03_need_vs_access",
           "Lower-income women: highest need, weakest coverage",
           "Bubble area = weighted population; dashed lines = all non-pregnant adults",
           NHANES_NOTE + "\nUninsured = HIQ011. Segments overlap; highly active men omitted (0.3% low ferritin).", "F03")
    register_figure("F03", "need_vs_access", "Need vs access quadrant", "NHANES adults 18+", "T02")

    # F04 threshold sensitivity -------------------------------------------
    segs = ["Non-pregnant females 20-44", "Adult women 18+", "Adults 18+", "Adult men 18+"]
    fig, ax = new_figure((0.27, 0.22, 0.66, 0.56))
    clean(ax)
    h = 0.26
    for k, (lab, c) in enumerate([("<15 WHO depleted stores", TEAL), ("<30 sensitivity", ORANGE),
                                  ("<50 sensitivity", INDIGO)]):
        vals = [thr[(thr.population_segment == s) & (thr.threshold_label == lab)].weighted_below_threshold_pct.iloc[0]
                for s in segs]
        yy = np.arange(len(segs)) + (k - 1) * (h + 0.03)
        ax.barh(yy, vals, height=h, color=c, label=lab.replace(" sensitivity", " ng/mL").replace(" WHO depleted stores", " ng/mL (WHO)"))
        for yv, v in zip(yy, vals):
            ax.text(v + 0.7, yv, f"{v:.1f}%", va="center", fontsize=11, color=INK)
    ax.set_yticks(np.arange(len(segs)), ["Non-pregnant women 20-44", "Women 18+", "All adults 18+", "Men 18+"])
    ax.invert_yaxis()
    ax.set_xlim(0, 65)
    pct_axis(ax)
    ax.set_xlabel("Weighted % below ferritin threshold")
    ax.legend(loc="lower right", frameon=False, fontsize=12)
    finish(fig, FIGS / "F04_threshold_sensitivity",
           "Flagging ferritin <30 makes the group 2.5x larger",
           "Threshold choice is a product-design decision with large market-size consequences",
           NHANES_NOTE + " Pregnant women excluded from adult and women 18+ groups.", "F04")
    register_figure("F04", "threshold_sensitivity", "Ferritin threshold sensitivity", "NHANES adults 18+", "T04")

    # F05 ferritin distribution -------------------------------------------
    fig, ax = new_figure((0.09, 0.20, 0.86, 0.58))
    clean(ax, "y")
    bins = np.logspace(0, np.log10(1000), 46)
    groups = [("Non-pregnant women 20-44", prim, TEAL),
              ("Men 18+", (base.sex == "Male") & (base.age_years >= 18), CONTEXT)]
    for lab, m, c in groups:
        sub = base[m]
        hist, edges = np.histogram(sub.ferritin_ng_ml, bins=bins, weights=sub.w)
        ax.stairs(100 * hist / hist.sum(), edges, color=c, linewidth=2.2, label=lab,
                  fill=False)
    for v, lab in [(15, "15"), (30, "30")]:
        ax.axvline(v, color=ORANGE, linestyle="--", linewidth=1.3)
        ax.text(v * 1.04, ax.get_ylim()[1] * 0.93, f"{lab} ng/mL", color=INK, fontsize=11)
    ax.set_xscale("log")
    ax.set_xticks([1, 5, 15, 30, 50, 100, 300, 1000], ["1", "5", "15", "30", "50", "100", "300", "1,000"])
    pct_axis(ax, "y")
    ax.set_xlabel("Serum ferritin, ng/mL (log scale)")
    ax.set_ylabel("Weighted % of group per bin")
    ax.legend(frameon=False, loc="upper left")
    finish(fig, FIGS / "F05_ferritin_distribution",
           "Women's ferritin runs about 4x lower than men's",
           f"Weighted median: non-pregnant women 20-44 {wmedian(base[prim]):.0f} ng/mL vs "
           f"men 18+ {wmedian(base[(base.sex == 'Male') & (base.age_years >= 18)]):.0f} ng/mL",
           NHANES_NOTE, "F05")
    register_figure("F05", "ferritin_distribution", "Ferritin distribution, women vs men", "NHANES", "analytics layer")

    # L01 listing ----------------------------------------------------------
    lst = con.execute("""
        SELECT CAST(patient_id AS BIGINT) AS nhanes_seqn, age_years, race_ethnicity,
               income_poverty_ratio_band, ROUND(ferritin_ng_ml, 1) AS ferritin_ng_ml,
               ROUND(hemoglobin_g_dl, 1) AS hemoglobin_g_dl, ROUND(hs_crp_mg_l, 2) AS hs_crp_mg_l,
               ROUND(transferrin_saturation_pct, 0) AS transferrin_saturation_pct,
               ROUND(mec_exam_weight, 0) AS mec_exam_weight
        FROM analytics.nhanes_early_iron_depletion_flags
        WHERE ferritin_lt15_without_anemia_flag = 1
        ORDER BY ferritin_ng_ml, nhanes_seqn""").df()
    assert len(lst) == lfwa.loc[0, "low_iron_without_anemia_unweighted_n"]
    save_listing("L01", "nhanes_low_ferritin_without_anemia_participants", lst,
                 "Participants with ferritin <15 ng/mL and hemoglobin >=12 g/dL",
                 "NHANES non-pregnant women 20-44", "analytics.nhanes_early_iron_depletion_flags")
    return dict(t02=t02, p_share=p_share, lo_s=lo_s, hi_s=hi_s, lfwa=lfwa)


# ---------------------------------------------------------------- MEPS
def meps(con):
    u = con.execute("SELECT * FROM mart.meps_utilization_access_by_segment ORDER BY segment_order").df()
    i = con.execute("SELECT * FROM mart.meps_insurance_oop_by_segment ORDER BY segment_order").df()
    save_table("T06", "meps_utilization_access_by_segment", u,
               "Health-care utilization and access barriers by iron-pathway segment",
               "MEPS adults 18+, 2023", "mart.meps_utilization_access_by_segment")
    save_table("T07", "meps_insurance_oop_by_segment", i,
               "Insurance coverage, income and out-of-pocket burden by segment",
               "MEPS adults 18+, 2023", "mart.meps_insurance_oop_by_segment")

    # F06 office visits
    fig, ax = new_figure((0.34, 0.20, 0.58, 0.61))
    clean(ax)
    y = np.arange(len(u))
    colors = [CONTEXT if t == "Reference" else (ORANGE if t == "Chronic condition" else TEAL)
              for t in u.segment_type]
    ax.barh(y, u.mean_office_visits, color=colors, height=0.62)
    for k, r in enumerate(u.itertuples()):
        flag = " *" if r.unweighted_n < 100 else ""
        ax.text(r.mean_office_visits + 0.3, k, f"{r.mean_office_visits:.1f}  (n={r.unweighted_n:,}){flag}",
                va="center", fontsize=12, color=INK)
    ax.set_yticks(y, u.population_segment, fontsize=12.5)
    ax.invert_yaxis()
    ax.set_xlim(0, 28)
    ax.set_xlabel("Mean office-based visits per person, 2023 (weighted)")
    finish(fig, FIGS / "F06_meps_office_visits",
           "Diagnosed patients already see clinicians twice as often",
           "Anemia, symptom and chronic-condition segments average 15-23 office visits vs 7 for all adults",
           MEPS_NOTE + "\n* n < 100: interpret with caution. Conditions are 3-digit ICD-10 codes "
           "(D50/D64, N92, Z34, R53/R42/L65, N18, I50).", "F06")
    register_figure("F06", "meps_office_visits", "Office visits by segment", "MEPS adults 18+", "T06")

    # F07 coverage mix (stacked)
    fig, ax = new_figure((0.34, 0.24, 0.58, 0.56))
    clean(ax)
    left = np.zeros(len(i))
    for lab, colname, c in [("Any private", "pct_any_private", TEAL),
                            ("Public only", "pct_public_only", INDIGO),
                            ("Uninsured all year", "pct_uninsured_all_year", ORANGE)]:
        vals = i[colname].to_numpy()
        ax.barh(np.arange(len(i)), vals, left=left, color=c, height=0.62, label=lab,
                edgecolor="white", linewidth=1.5)
        for k, v in enumerate(vals):
            if v >= 9:
                ax.text(left[k] + v / 2, k, f"{v:.0f}%", ha="center", va="center", color="white",
                        fontsize=11.5, weight="bold")
        left += vals
    ax.set_yticks(np.arange(len(i)), i.population_segment, fontsize=12.5)
    ax.invert_yaxis()
    ax.set_xlim(0, 100)
    pct_axis(ax)
    ax.legend(loc="upper center", bbox_to_anchor=(0.45, -0.1), ncol=3, frameon=False, fontsize=12)
    finish(fig, FIGS / "F07_meps_coverage_mix",
           "Chronic-condition segments are majority publicly insured",
           "Heart failure and CKD: 60-65% public-only, so access runs through Medicare/Medicaid policy",
           MEPS_NOTE + " Coverage = INSCOV23. Segments with n < 100: menstruation, D50, CKD.", "F07")
    register_figure("F07", "meps_coverage_mix", "Coverage mix by segment", "MEPS adults 18+", "T07")
    return dict(u=u, i=i)


# ---------------------------------------------------------------- Synthea
def synthea(con):
    seg = con.execute("SELECT * FROM mart.risk_segment_clinical_opportunity ORDER BY opportunity_rank").df()
    path = con.execute("SELECT * FROM mart.utilization_pathway_by_segment").df()
    setting = con.execute("SELECT * FROM mart.target_condition_encounter_setting "
                          "ORDER BY target_condition_encounters DESC").df()
    payer = con.execute("SELECT payer_name, unique_target_patients, share_of_target_patients_pct "
                        "FROM mart.latest_recorded_payer_mix ORDER BY payer_mix_rank").df()
    org = con.execute("SELECT * FROM mart.organization_opportunity ORDER BY organization_opportunity_rank").df()
    kpi = con.execute("SELECT * FROM mart.dashboard_kpi_summary ORDER BY display_order").df()

    save_table("T08", "synthea_risk_segment_opportunity", seg.merge(path, on=["risk_segment", "unique_patients"]),
               "Synthetic target cohort: segments, encounters and pre/post-diagnosis pathway",
               "Synthea target cohort (n=563)", "mart.risk_segment_clinical_opportunity + utilization_pathway_by_segment")
    save_table("T09", "synthea_encounter_setting", setting,
               "Care setting of target-condition encounters", "Synthea target cohort",
               "mart.target_condition_encounter_setting")
    save_table("T10", "synthea_latest_payer_mix", payer, "Latest recorded payer mix",
               "Synthea target patients with payer history (n=558)", "mart.latest_recorded_payer_mix")
    cols = ["organization_opportunity_rank", "organization_name", "organization_city", "unique_target_patients",
            "target_condition_encounters", "repeat_target_patient_pct", "anemia_segment_patients",
            "pregnancy_segment_patients", "kidney_segment_patients", "heart_failure_segment_patients",
            "ambulatory_encounters", "emergency_encounters"]
    save_table("T11", "synthea_top_organizations", org[cols].head(15),
               "Top 15 synthetic organizations by target-patient reach", "Synthea target cohort",
               "mart.organization_opportunity")
    save_table("T12", "synthea_dashboard_kpis", kpi, "Synthetic pathway KPI summary", "Synthea target cohort",
               "mart.dashboard_kpi_summary")

    # F08 encounter setting
    fig, ax = new_figure((0.22, 0.30, 0.70, 0.46))
    clean(ax)
    s = setting.copy()
    ax.barh(np.arange(len(s)), s.share_of_target_condition_encounters_pct,
            color=[TEAL, TEAL, CONTEXT, CONTEXT], height=0.6)
    for k, r in enumerate(s.itertuples()):
        ax.text(r.share_of_target_condition_encounters_pct + 1, k,
                f"{r.share_of_target_condition_encounters_pct:.1f}%  |  {r.target_condition_encounters:,} "
                f"encounter{'s' if r.target_condition_encounters != 1 else ''}",
                va="center", fontsize=12.5, color=INK)
    ax.set_yticks(np.arange(len(s)), s.encounter_class.str.capitalize(), fontsize=14)
    ax.invert_yaxis()
    ax.set_xlim(0, 100)
    pct_axis(ax)
    ax.set_xlabel("Share of target-condition encounters")
    finish(fig, FIGS / "F08_synthea_encounter_setting",
           "97% of target-condition visits are ambulatory or wellness",
           "Primary-care and wellness touchpoints are the natural placement for a triage test",
           SYN_NOTE, "F08")
    register_figure("F08", "synthea_encounter_setting", "Encounter setting", "Synthea", "T09")

    # F09 organization concentration curve
    o = org.sort_values("unique_target_patients", ascending=False).reset_index(drop=True)
    n = len(o)
    x = np.r_[0, np.arange(1, n + 1) / n * 100]
    total = o.unique_target_patients.sum()
    yv = np.r_[0, o.unique_target_patients.cumsum() / total * 100]
    fig, ax = new_figure((0.10, 0.20, 0.84, 0.58))
    clean(ax, "both")
    ax.plot(x, yv, color=TEAL, linewidth=2.5)
    ax.plot([0, 100], [0, 100], color=CONTEXT, linestyle="--", linewidth=1.3)
    for frac, (dx, dy) in [(0.10, (2, -9)), (0.25, (2, -9))]:
        k = int(np.ceil(frac * n))
        ax.scatter([x[k]], [yv[k]], s=60, color=TEAL, zorder=3)
        ax.text(x[k] + dx, yv[k] + dy, f"Top {frac:.0%} of organizations: {yv[k]:.0f}% of memberships",
                fontsize=12, color=INK)
    ax.text(70, 62, "Equal-share reference", rotation=33, color=MUTED, fontsize=11)
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 103)
    pct_axis(ax)
    pct_axis(ax, "y")
    ax.set_xlabel("Cumulative share of organizations (most target patients first)")
    ax.set_ylabel("Cumulative share of patient memberships")
    k10 = int(np.ceil(0.10 * n))
    finish(fig, FIGS / "F09_synthea_organization_concentration",
           f"Top 10% of organizations hold {yv[k10]:.0f}% of patient memberships",
           f"{n} synthetic organizations; a patient can be counted at several organizations",
           SYN_NOTE, "F09")
    register_figure("F09", "synthea_organization_concentration", "Organization concentration", "Synthea", "T11")

    # L02 synthetic patient pathway listing (IDs shortened)
    lst = con.execute("""
        SELECT LEFT(patient_id, 8) AS synthetic_patient_id, risk_segment, first_segment_condition_date,
               encounters_pre_365, encounters_post_365, cbc_observation_days_pre_365,
               cbc_observation_days_on_or_post_365, iron_medication_start_days_on_or_post_365
        FROM mart.segment_patient_pathway_summary
        ORDER BY risk_segment, first_segment_condition_date""").df()
    save_listing("L02", "synthea_patient_segment_pathway", lst,
                 "Patient-segment pathway: encounters and CBC signals 365 days pre/post index",
                 "Synthea target cohort (726 patient-segment rows)", "mart.segment_patient_pathway_summary")
    return dict(seg=seg, path=path, setting=setting, payer=payer, kpi=kpi, org_top10=yv[k10])


def qa_listing(con):
    frames = []
    for src, tbl in [("NHANES", "mart.nhanes_final_validation_summary"),
                     ("MEPS", "mart.meps_final_validation_summary"),
                     ("Synthea", "mart.final_validation_summary")]:
        d = con.execute(f"SELECT * FROM {tbl} ORDER BY check_order").df()
        d.insert(0, "source", src)
        frames.append(d)
    qa = pd.concat(frames, ignore_index=True)
    assert (qa.status == "PASS").all()
    save_listing("L03", "qa_validation_checks", qa, "All pipeline validation checks",
                 "All sources", "mart.*_validation_summary")


def main():
    for d in (TABLES, FIGS, LISTS):
        d.mkdir(parents=True, exist_ok=True)
    with duckdb.connect(str(ROOT / "database" / "market_access.duckdb"), read_only=True) as con:
        r_n = nhanes(con)
        meps(con)
        synthea(con)
        qa_listing(con)
    with pd.ExcelWriter(TABLES / "tfl_tables.xlsx") as xw:
        pd.DataFrame(INDEX).to_excel(xw, sheet_name="Index", index=False)
        for number, df in SHEETS.items():
            df.to_excel(xw, sheet_name=number, index=False)
    pd.DataFrame(INDEX).to_csv(OUT / "tfl_index.csv", index=False)
    print(f"{len(INDEX)} outputs written. Primary share not anemic: {r_n['p_share']:.1f}% "
          f"({r_n['lo_s']:.1f}-{r_n['hi_s']:.1f})")


if __name__ == "__main__":
    main()
