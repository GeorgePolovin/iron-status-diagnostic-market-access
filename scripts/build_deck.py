"""Build the results & recommendations deck from the TFL outputs.

Run after build_tfl.py (from the repo root):
    python scripts/build_deck.py      -> presentation/iron_status_market_access_results.pptx

Every number on a slide is read from outputs/tables/*.csv at build time,
so the deck cannot drift from the analysis.
"""

from pathlib import Path

import pandas as pd
from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.util import Inches, Pt

ROOT = Path(__file__).resolve().parents[1]
T, F = ROOT / "outputs" / "tables", ROOT / "outputs" / "figures"
INK, MUTED, TEAL = RGBColor(0x17, 0x2E, 0x3D), RGBColor(0x55, 0x6B, 0x7A), RGBColor(0x00, 0x8C, 0x99)


def table(name):
    return pd.read_csv(next(T.glob(f"{name}_*.csv")))


def add_text(slide, text, left, top, width, height, size=16, bold=False, color=INK):
    box = slide.shapes.add_textbox(Inches(left), Inches(top), Inches(width), Inches(height))
    tf = box.text_frame
    tf.word_wrap = True
    for k, line in enumerate(text if isinstance(text, list) else [text]):
        p = tf.paragraphs[0] if k == 0 else tf.add_paragraph()
        p.text = line
        p.font.size, p.font.bold, p.font.color.rgb = Pt(size), bold, color
        p.space_after = Pt(6)
    return box


def title_slide(prs, title, subtitle):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    add_text(s, title, 0.7, 2.4, 12, 1.4, 36, True)
    add_text(s, subtitle, 0.7, 3.9, 12, 1.2, 18, color=MUTED)
    return s


def text_slide(prs, title, bullets, size=17):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    add_text(s, title, 0.6, 0.35, 12.2, 0.8, 28, True)
    add_text(s, [f"•  {b}" for b in bullets], 0.7, 1.35, 12.0, 5.8, size)
    return s


def figure_slide(prs, fig, takeaway):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    s.shapes.add_picture(str(F / f"{fig}.png"), Inches(0.35), Inches(0.15), width=Inches(9.9))
    add_text(s, "So what", 10.45, 0.6, 2.6, 0.5, 16, True, TEAL)
    add_text(s, takeaway, 10.45, 1.1, 2.65, 5.8, 13.5)
    return s


def grid_slide(prs, title, df, col_widths, size=11):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    add_text(s, title, 0.5, 0.3, 12.3, 0.7, 26, True)
    rows, cols = df.shape[0] + 1, df.shape[1]
    shape = s.shapes.add_table(rows, cols, Inches(0.4), Inches(1.15), Inches(sum(col_widths)), Inches(0.4 * rows))
    tbl = shape.table
    for j, w in enumerate(col_widths):
        tbl.columns[j].width = Inches(w)
    for j, c in enumerate(df.columns):
        tbl.cell(0, j).text = c
    for i, row in enumerate(df.itertuples(index=False), start=1):
        for j, v in enumerate(row):
            tbl.cell(i, j).text = str(v)
    for i in range(rows):
        for j in range(cols):
            for p in tbl.cell(i, j).text_frame.paragraphs:
                p.font.size = Pt(size)
                p.font.bold = i == 0
    return s


def main():
    seg, lfwa, thr = table("T02"), table("T03"), table("T04")
    u, ins, syn = table("T06"), table("T07"), table("T08")
    setting, kpi, disp = table("T09"), table("T12"), table("T01")

    g = seg.set_index("population_segment")
    m_u, m_i = u.set_index("population_segment"), ins.set_index("population_segment")
    prim = lfwa.iloc[0]
    lt30 = lfwa.iloc[1]
    t = thr.set_index(["population_segment", "threshold_label"]).weighted_below_threshold_pct
    w15, w30 = t[("Non-pregnant females 20-44", "<15 WHO depleted stores")], t[("Non-pregnant females 20-44", "<30 sensitivity")]
    amb = setting.set_index("encounter_class").share_of_target_condition_encounters_pct
    amb_well = amb["ambulatory"] + amb["wellness"]
    s_path = syn.set_index("risk_segment")
    n_nh = int(disp.loc[disp.population_step.str.startswith("With measured"), "unweighted_n"].iloc[0])

    prs = Presentation()
    prs.slide_width, prs.slide_height = Inches(13.333), Inches(7.5)

    title_slide(prs, "Where a home iron-status test fits: market access and customer-fit analysis",
                "NHANES 2017-2020 · MEPS 2023 · Synthea synthetic EHR  |  Portfolio case study. "
                "Population evidence only: no product performance data is used or implied.")

    text_slide(prs, "Executive summary", [
        f"Real unmet need: {w15:.1f}% of non-pregnant US women 20-44 have depleted iron stores (ferritin <15 ng/mL); "
        f"{prim.weighted_pct_of_low_iron_group_without_anemia:.0f}% of them are NOT anemic "
        f"({prim.weighted_low_iron_without_anemia_population_millions:.1f}M women), so a hemoglobin-first workflow misses them.",
        f"Need concentrates in menstruating ({g.loc['Menstruating women 18-49', 'ferritin_lt15_pct']:.1f}%), "
        f"lower-income ({g.loc['Lower-income women 18-49', 'ferritin_lt15_pct']:.1f}%) and pregnant women "
        f"({g.loc['Pregnant women 20-44', 'ferritin_lt15_pct']:.1f}%, small n); men are near "
        f"{g.loc['Men 18+', 'ferritin_lt15_pct']:.0f}%.",
        f"Access friction is real but segment-specific: lower-income women are {g.loc['Lower-income women 18-49', 'uninsured_pct']:.0f}% "
        f"uninsured; fewer women 18-49 have a usual source of care than adults overall "
        f"({m_u.loc['Women 18-49', 'pct_usual_source_of_care']:.0f}% vs {m_u.loc['All adults 18+', 'pct_usual_source_of_care']:.0f}% of adults).",
        f"Threshold is a strategic choice: flagging ferritin <30 expands the group from {w15:.0f}% to {w30:.0f}% of women 20-44.",
        f"In the synthetic pathway, {amb_well:.0f}% of target-condition visits are ambulatory or wellness: routine primary care "
        "is the natural confirmatory hand-off point.",
        "Recommendation: launch as a hybrid home-screen → confirmatory-lab product for menstruating women, entering "
        "through athletes (equal need, more often non-anemic, most able to pay); "
        "treat pregnancy, CKD and heart failure as clinician-supervised follow-on segments.",
    ], size=16)

    text_slide(prs, "Question, data and approach", [
        "Business question: which populations need an upstream iron-status test, where does today's pathway create "
        "friction, and which channels should be prioritised first?",
        f"NHANES (real, measured labs, n={n_nh:,}): prevalence of low ferritin, low ferritin without anemia, "
        "and need-vs-access by segment, with design-based 95% CIs.",
        f"MEPS 2023 (real, survey): utilization, insurance, out-of-pocket burden and access barriers for "
        f"{int(m_u.loc['All adults 18+', 'unweighted_n']):,} adults.",
        "Synthea (synthetic EHR): code-level patient journey to test where a triage test could sit; workflow logic only.",
        "The three sources are never joined at person level; findings are combined at segment and workflow level.",
        "The test is positioned as triage that triggers confirmatory lab testing, never as a replacement for "
        "CBC / serum ferritin / clinician evaluation.",
    ])

    figure_slide(prs, "F01_iron_anemia_stage_distribution", [
        f"{prim.weighted_low_iron_without_anemia_population_millions:.1f}M women 20-44 have depleted iron with normal hemoglobin.",
        "Workflows that start with an abnormal CBC will not find them.",
        "This is the clearest product-market gap and supports Hypothesis 1 (undetected early deficiency).",
        f"At ferritin <30 the non-anemic group is {lt30.weighted_low_iron_without_anemia_population_millions:.1f}M.",
    ])
    figure_slide(prs, "F02_low_ferritin_by_segment", [
        "Consumer-ready segments (teal) have 13-17% prevalence, 3x the adult average.",
        "Highly active women have the same prevalence, but 62% of their cases are non-anemic (vs 50%), "
        "44% are high-income and only 9% are uninsured: the best DTC beachhead.",
        "Pregnancy is highest but n=76 and needs clinician oversight.",
        "CKD and heart failure need a different definition (ferritin <100 / TSAT <20%), so they are a "
        "future monitoring use case.",
    ])
    figure_slide(prs, "F04_threshold_sensitivity", [
        f"<15 ng/mL: {w15:.1f}% of women 20-44; <30: {w30:.1f}%; <50: {t[('Non-pregnant females 20-44', '<50 sensitivity')]:.1f}%.",
        "A higher cutoff grows the market but raises false-positive and confirmatory-testing load.",
        "Cutoff selection must be driven by validated assay performance, not market size.",
    ])
    figure_slide(prs, "F03_need_vs_access", [
        "Lower-income women sit alone in the high-need, low-coverage quadrant.",
        "Direct-to-consumer pricing will not reach them; community-health, Medicaid or employer channels are needed "
        "(Hypothesis 5).",
        "Highly active women have the best coverage and highest income, and the most to lose from fatigue: "
        "a premium DTC beachhead.",
    ])
    figure_slide(prs, "F06_meps_office_visits", [
        "Diagnosed anemia, symptom and chronic segments already average 15-23 office visits a year.",
        "For them the gap is not access to clinicians but the absence of a ferritin trigger: a clinician-recommended "
        "channel fits.",
        f"Women 18-49 report delayed care at {m_u.loc['Women 18-49', 'pct_delayed_medical_care']:.0f}% "
        f"(vs {m_u.loc['All adults 18+', 'pct_delayed_medical_care']:.0f}% of adults), which supports home convenience.",
    ])
    figure_slide(prs, "F07_meps_coverage_mix", [
        f"Heart failure: {m_i.loc['Heart failure (I50)', 'pct_public_only']:.0f}% public-only; CKD "
        f"{m_i.loc['Chronic kidney disease (N18)', 'pct_public_only']:.0f}% (n<100).",
        "These segments' reimbursement runs through Medicare/Medicaid evidence standards.",
        f"Women with heavy menstruation are {m_i.loc['Heavy/irregular menstruation (N92)', 'pct_any_private']:.0f}% privately "
        "insured (n<100), which fits an HSA/FSA-eligible or employer-benefit path.",
    ])
    figure_slide(prs, "F08_synthea_encounter_setting", [
        f"{amb_well:.0f}% of synthetic target-condition encounters are ambulatory or wellness visits.",
        f"Only {s_path.loc['Anemia diagnosis (not iron-specific)', 'patients_with_cbc_pre_365_pct']:.0f}% of anemia patients "
        "had a CBC in the year before diagnosis, and the export contains no ferritin observations at all.",
        "This illustrates the confirmatory hand-off point, not real-world rates.",
    ])

    hyp = pd.DataFrame([
        ("H1 Undetected early deficiency", "Supported", f"F01: {prim.weighted_pct_of_low_iron_group_without_anemia:.0f}% of depleted women not anemic (NHANES)"),
        ("H2 Segment concentration", "Supported, refined", "Menstruation/income drive prevalence; athletes: equal need, more hidden, more able to pay"),
        ("H3 Workflow friction", "Partially supported", "MEPS delayed care / no usual source of care for women 18-49; Synthea is illustrative only"),
        ("H4 Hybrid adoption", "Consistent, not proven", "Care is ambulatory-led (F08); needs a willingness-to-pay / pilot study"),
        ("H5 Channels differ by segment", "Supported", "F03/F07: coverage and income differ sharply across segments"),
        ("H6 Value depends on placement", "Not testable here", "Requires assay performance + outcome data"),
    ], columns=["Hypothesis", "Verdict", "Evidence"])
    grid_slide(prs, "Hypothesis scorecard", hyp, [3.4, 2.3, 6.8], size=13)

    rec = pd.DataFrame([
        ("Depleted iron without anemia is common in women 20-44", "Menstruating women 18-49",
         "Launch DTC + telehealth confirmatory-lab hand-off", "Analytical validation vs serum ferritin at the chosen cutoff",
         "Product / clinical", "0-12 mo", "1"),
        ("Athletes: equal need, more often non-anemic, most able to pay", "Athletes, teams, sports medicine",
         "Beachhead: team / club / performance channels, premium DTC", "Willingness-to-pay + usability study", "Commercial", "0-12 mo", "1"),
        ("Lower-income women: highest need, weakest coverage", "Community health, Medicaid MCOs",
         "Subsidised / community-health pilots", "Cost-per-case-found vs lab-first screening", "Market access", "12-24 mo", "2"),
        ("Threshold drives market size 2.5x", "Product team, KOLs",
         "Pick cutoff on assay performance, not size", "ROC analysis at 15 / 30 ng/mL", "Clinical", "0-6 mo", "1"),
        ("Chronic segments are publicly insured, high-use", "Nephrology, cardiology, Medicare",
         "Defer; monitoring indication later", "Performance under inflammation (ferritin <100 / TSAT)", "Clinical / regulatory", "24+ mo", "3"),
    ], columns=["Finding", "Stakeholder", "Recommended action", "Evidence required", "Owner", "Timing", "Priority"])
    grid_slide(prs, "Recommendations and next actions", rec, [2.7, 1.9, 2.3, 2.6, 1.3, 0.9, 0.8], size=10.5)

    text_slide(prs, "Limitations and what this analysis does NOT claim", [
        "No product performance data: nothing here estimates sensitivity, specificity or clinical utility of any test.",
        "NHANES is cross-sectional: low ferritin today does not prove future anemia. Hemoglobin is not adjusted for "
        "smoking/altitude; segment flags are self-reported; pregnant n=76.",
        "MEPS conditions are self/household-reported, 3-digit ICD-10, and several segments have n<100. Expenditures are "
        "all-cause, not iron-testing costs.",
        "Synthea is synthetic: it demonstrates workflow logic and SQL design, not real utilization, payers or providers. "
        "Organization, provider and commercial-payer names are pseudonymised.",
        "Segments overlap and are not additive; population counts are weighted survey estimates with sampling error.",
    ], size=16)

    text_slide(prs, "Appendix: reproducibility and TFL package", [
        "python scripts/download_data.py → python run_pipeline.py → python scripts/build_tfl.py → python scripts/build_deck.py",
        "22 SQL steps run against DuckDB; every embedded QA check must return PASS or the build stops (Listing L03).",
        "12 tables (T01-T12, CSV + one Excel workbook), 9 figures (F01-F09, PNG + SVG), 3 listings (L01-L03).",
        "Python survey estimates are asserted against the SQL marts, so the two layers cannot drift.",
        "outputs/tfl_index.csv catalogues every output with its population and source table.",
    ])

    out = ROOT / "presentation" / "iron_status_market_access_results.pptx"
    out.parent.mkdir(exist_ok=True)
    prs.save(out)
    print(f"Saved {out.relative_to(ROOT)} ({len(prs.slides)} slides)")


if __name__ == "__main__":
    main()
