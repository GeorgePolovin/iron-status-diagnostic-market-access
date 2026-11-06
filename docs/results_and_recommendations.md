# Results and Recommendations

**Project:** Market-access and customer-fit analysis for an at-home iron-status (ferritin) rapid test concept
**Data:** NHANES 2017–March 2020 (real, measured labs) · MEPS 2023 (real, national survey) · Synthea (fully synthetic EHR)
**Companion files:** [analysis plan](analysis_plan.md) · TFL outputs in `outputs/` (numbers below cite them as T## / F## / L##) · deck in `presentation/`

> No finding here describes the performance of any actual test. These are population, utilization and
> workflow findings that set out what a test would need to do and for whom.

---

## 1. The business decision in one paragraph

**Recommended decision: launch first as a direct-to-consumer, at-home *screen-and-refer* product for
non-pregnant menstruating women aged 18–49, entering through highly active and athletic women as the
beachhead. A positive or borderline result routes the user to a confirmatory serum-ferritin lab test
(telehealth or retail lab). The test does not diagnose.
Pregnancy, chronic kidney disease and heart failure are deferred to later, clinician-supervised
indications.** Commercialization should be gated on one decision that the data shows is decisive:
**the ferritin cutoff (15 vs 30 ng/mL)**. That choice changes the addressable group by 2.5x, and it has
to be set by validated assay accuracy, not by market size.

### What this decision means in practice

| If you adopt it, you commit to… | …and you explicitly do NOT |
|---|---|
| A consumer brand aimed at women 18–49, entered through athletes and highly active women (teams, clubs, coaches, sports-medicine and performance channels), then e-commerce, women's-health telehealth and retail pharmacy | Build a clinician sales force for the first launch |
| A confirmatory-lab partnership (e.g. telehealth + retail lab ordering) as part of the product | Claim the test replaces CBC, serum ferritin or a clinician's evaluation |
| A validation study against serum ferritin at the chosen cutoff, before any performance claim | Pursue Medicare/CKD/heart-failure reimbursement at launch |
| A second channel (community health / Medicaid / employer) for lower-income women once cost-per-case-found is shown | Price only for affluent self-pay buyers and ignore the highest-need group |

---

## 2. Key results by proposal question

### 2.1 Population and unmet need (NHANES)

| Result | Value | Source |
|---|---|---|
| Non-pregnant women 20–44 with depleted iron stores (ferritin <15 ng/mL) | **13.5%** (≈6.4M women) | T03, T04 |
| …of whom are **not anemic** (Hb ≥12 g/dL) | **55%** (95% CI 47.5–62.5%) | T03, F01 |
| Women 20–44 with depleted iron and *normal hemoglobin* | **3.5M** (7.4% of the group; CI 6.1–8.8%) | T03, F01 |
| Same group at the ferritin <30 sensitivity threshold | 25.2% → **11.9M** women | T03 |
| Inflammation-aware (CRP) sensitivity estimate | 26.6% low iron; 9.2M without anemia | T03, T05 |
| Men 18+ with ferritin <15 | 1.0% | T02, F02 |

**Answer:** a large, measurable group has depleted iron *before* anemia. Workflows that only work up
an abnormal hemoglobin or CBC miss most of it. This is the core product-market gap.

**Risk differs sharply by segment** (ferritin <15 ng/mL, weighted, 95% CI; T02, F02):

| Segment | % ferritin <15 | 95% CI | % uninsured | Read-out |
|---|---|---|---|---|
| Menstruating women 18–49 | **15.3%** | 12.7–17.8 | 14.5% | Largest high-need group (≈7.5M) |
| Lower-income women 18–49 (<100% FPL) | **16.5%** | 13.1–19.8 | **27.4%** | Highest need + weakest coverage |
| Highly active women 18–49 | 13.2% | 9.3–17.0 | **8.6%** | Same prevalence; 62% of cases non-anemic; most affluent and best insured |
| Pregnant women 20–44 | 24.2% | 13.9–34.6 | 9.8% | Highest, but n=76; needs clinician oversight |
| Adults with weak/failing kidneys | 2.9% | 0.6–5.3 | 9.1% | Ferritin <15 is the wrong definition here |
| Adults with heart failure | 2.5% | 0.9–4.0 | 2.3% | 51% meet the heart-failure iron-deficiency definition (ferritin <100 or TSAT <20%) |
| Men 18+ (reference) | 1.0% | 0.5–1.4 | 16.1% | Not a target |

**Answers to the plan's segment questions:**
- **Athletes and highly active women are the best beachhead, for commercial reasons rather than
  higher prevalence.** Their rate of depleted iron matches other women their age (13.2% vs 13.9%),
  so the biological need is the same. Three things make them the strongest first buyers:
  1. **Ability and willingness to pay:** 44% have household income ≥4x the poverty line (vs 35% of
     women 18–49), and only 8.6% are uninsured (vs 14.6%), which fits DTC self-pay (T02).
  2. **The deficiency is more often hidden:** 62% of depleted, highly active women are *not* anemic
     (vs 50% of all women 18–49; 95% CIs 47–78% vs 44–57%, so the result points the same way but is
     not significant, T02). A hemoglobin-based check is least likely to catch them.
  3. **The symptoms cost them more:** non-anemic iron deficiency mostly shows up as fatigue and
     reduced endurance. A sedentary person who is tired can live with it. Someone who has to train
     and perform at a high level notices it and acts on it. This is the domain rationale, and it fits
     sports-medicine evidence that non-anemic iron deficiency impairs endurance capacity. NHANES does
     not measure performance or willingness to pay, so this still needs a WTP and usability study.
  The resulting go-to-market is: enter through athletes, expand to all menstruating women 18–49 (the
  large market, about 7.5M women with depleted iron).
- **Lower-income women are the only segment that combines high need with limited access** (F03).
- **CKD and heart failure have real iron deficiency, but at a different threshold** (ferritin <100, or
  100–299 with transferrin saturation <20%). A test built around low ferritin cutoffs does not serve
  them. That is a different product.

### 2.2 Current clinical workflow (MEPS + Synthea)

| Result | Value | Source |
|---|---|---|
| Mean office visits/year: anemia dx · symptom proxy · heart failure · CKD | 14.8 · 14.8 · 16.4 · 23.1 (vs 7.3 all adults) | T06, F06 |
| Women 18–49 with a usual source of care | **64.7%** (vs 70.6% all adults) | T06 |
| Women 18–49 who delayed medical care | **10.0%** (vs 7.2% all adults) | T06 |
| Synthetic target-condition encounters in ambulatory/wellness settings | **97%** | T09, F08 |
| Synthetic anemia patients with a CBC in the year *before* diagnosis | 6% | T08 |
| Ferritin / iron-panel observations in the synthetic EHR | 0 | L03 |

**Answers:**
- **Who controls the pathway:** routine ambulatory and primary-care/wellness visits, not hospitals
  (Synthea, F08). Confirmatory testing should hand off to primary care, telehealth or a retail lab.
- **Where home testing removes friction:** young women are *less* attached to a usual source of care
  and delay care more often than adults overall. Convenience is a real benefit for exactly the
  high-need group.
- **Already-diagnosed and chronic patients see clinicians constantly** (15–23 visits/year). Their gap
  is not access but the lack of a ferritin trigger, so a clinician-recommended channel fits them later.
- **When the product must stay under clinician supervision:** pregnancy, CKD, heart failure, and any
  result suggesting anemia or blood loss.
- *Not answerable with this data:* "How many visits/tests occur before diagnosis?" Synthea shows the
  logic, but it is synthetic and contains no ferritin tests. Real claims data is needed.

### 2.3 Customer adoption and market access (MEPS + NHANES)

| Segment | Coverage mix | Annual OOP | Implied channel | Source |
|---|---|---|---|---|
| Women 18–49 | 72% private · 20% public · 8% uninsured | $942 | Direct-to-consumer, HSA/FSA, employer benefit | T07 |
| Heavy/irregular menstruation (n<100) | 77% private | $1,040 | DTC + women's-health telehealth | T07 |
| Lower-income women (NHANES) | 27% uninsured; 100% below poverty | — | Community health / Medicaid / subsidised | T02 |
| Heart failure / CKD (n<100 for CKD) | 65% / 60% public-only | $3,782 / $3,199 | Medicare/Medicaid evidence pathway, later | T07, F07 |

**Strongest initial opportunity: direct-to-consumer with a confirmatory-lab hand-off** for menstruating
women. Payer-sponsored access is the right path only for the chronic segments, and it needs clinical
utility evidence that does not exist yet.

---

## 3. Hypothesis verdicts

| # | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| H1 | Meaningful population has low iron stores without anemia | **Supported** | 55% of depleted women 20–44 are non-anemic; 3.5M women (F01, T03) |
| H2 | Need concentrates in menstruating / highly active women / symptomatic | **Supported, refined** | Menstruation and low income drive prevalence; highly active women have equal prevalence but more often non-anemic deficiency and greater ability to pay (F02, T02) |
| H3 | Patients face friction before iron testing | **Partially supported** | Women 18–49: less usual-source-of-care, more delayed care (T06); test-sequence friction needs real claims |
| H4 | Hybrid home-screen → confirmatory-lab model is strongest | **Consistent, not proven** | Care is ambulatory-led (F08); needs a willingness-to-pay / pilot study |
| H5 | Different segments need different channels | **Supported** | Coverage, income and OOP differ sharply (F03, F07) |
| H6 | Value depends on placement, not standalone diagnosis | **Not testable here** | Requires assay performance and outcome data |

---

## 4. Recommendations and actions

Format follows the analysis plan: finding → stakeholder → implication → action → evidence → owner → timing → priority.

| # | Finding | Population / stakeholder | Business implication | Recommended action | Evidence required | Owner | Timing | Priority |
|---|---|---|---|---|---|---|---|---|
| 1 | 3.5M women 20–44 have depleted iron with normal Hb | Menstruating women 18–49 | Clear unmet need that hemoglobin-first care misses | Launch DTC screen-and-refer kit with telehealth/retail-lab confirmatory hand-off | Analytical validation vs serum ferritin at the chosen cutoff | Product + clinical | 0–12 mo | **1** |
| 2 | Cutoff 15 vs 30 ng/mL changes the group 2.5x | Product team, clinical advisors | Biggest single driver of market size *and* false-positive load | Set the cutoff on assay accuracy (ROC at 15/30); report both | Paired study, sensitivity/specificity at both cutoffs | Clinical | 0–6 mo | **1** |
| 3 | Women 18–49 delay care and lack a usual source of care | Women's-health telehealth, retail pharmacy | Convenience is the value proposition, not price alone | Partner for result → consult → lab order in one flow | Pilot: % of positives completing confirmatory test | Commercial | 6–12 mo | **1** |
| 4 | Highly active women: same prevalence, deficiency more often non-anemic (62%), most affluent (44% ≥4x poverty), best insured; performance makes symptoms costly | Athletes, sports teams, collegiate programs, coaches, sports-medicine clinics | Most motivated, best-able-to-pay first buyers: the beachhead | Launch through team/club and performance channels; premium DTC positioning; use as proof-of-value case studies | Willingness-to-pay + usability study; performance-symptom outcomes in a pilot | Commercial | 0–12 mo | **1** |
| 5 | Lower-income women: highest need, 27% uninsured | Community health centers, Medicaid managed care, employers | DTC price excludes the neediest group | Subsidised or community-health pilot after launch | Cost-per-case-found vs lab-first screening | Market access | 12–24 mo | 2 |
| 6 | 24% of pregnant women have ferritin <15 (n=76) | Obstetric clinicians | High need, but regulated care setting | Position as a clinician-ordered adjunct only; no DTC pregnancy claim | Validation in pregnancy; clinical guideline review | Clinical/regulatory | 18–24 mo | 3 |
| 7 | HF/CKD: ~half iron-deficient by HF definition; majority publicly insured | Cardiology, nephrology, Medicare | Different threshold = different product | Defer; explore a monitoring indication | Performance at ferritin 100–300 and with TSAT; inflammation robustness | Clinical/regulatory | 24+ mo | 3 |
| 8 | Synthetic pathway: no ferritin before diagnosis; ambulatory-led | Analytics | Real-world test-sequence friction is still unmeasured | Replicate the SQL pathway on real claims/EHR data | Licensed claims or EHR extract | Analytics | 6–12 mo | 2 |

---

## 5. Limitations

- **No test performance data.** Every number is population evidence. None of it estimates the
  accuracy or clinical utility of any product.
- **NHANES** is cross-sectional (low ferritin now does not prove future anemia). Hemoglobin is not
  adjusted for smoking or altitude. Questionnaire segments are self-reported. Pregnant n=76, and three
  segments have relative SE >30% (flagged in T02).
- **MEPS** conditions are self-reported 3-digit ICD-10 codes, and several segments have n<100
  (flagged). Expenditures are all-cause, not iron-testing costs.
- **Synthea** is synthetic. It demonstrates workflow logic and SQL design, not real utilization.
  Facility, clinician and commercial-payer names are pseudonymized.
- Segments overlap and are not additive. Weighted counts carry sampling error (95% CIs where shown).
