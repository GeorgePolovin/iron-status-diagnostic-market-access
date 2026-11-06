# Analysis Plan

This is the original plan the analysis was built against. Results are in
[results_and_recommendations.md](results_and_recommendations.md).

## Product concept

A non-invasive, at-home rapid test that classifies iron stores as potentially low, borderline or
adequate, and directs users to confirmatory laboratory testing and clinical care. It is modeled as:

- an upstream risk-identification tool
- a home or point-of-care triage tool
- a trigger for confirmatory laboratory testing
- a possible monitoring adjunct between clinical blood tests

It is **not** modeled as a replacement for a CBC, serum ferritin, transferrin saturation or a
clinician-directed evaluation.

## Questions

**Population and unmet need.** Which populations have the highest prevalence of low ferritin? How
many people have low ferritin before developing anemia? How does risk differ among menstruating
women, highly active people, pregnant people, lower-income families, and people with CKD or heart
failure? Which populations combine high need with limited access to testing?

**Clinical workflow.** What initiates an iron-deficiency evaluation? Who receives a CBC, ferritin or
iron panel? Which specialties and settings control the pathway? Where could home testing reduce
delay or unnecessary visits? When must the test remain under clinician supervision?

**Adoption and market access.** Which patients and clinicians are most likely to use it? Is the
strongest initial channel direct-to-consumer, clinical, employer, retail, community-health or payer?
How do insurance, income and out-of-pocket burden affect adoption? Which evidence gaps block
stronger claims?

## Simplified patient journey (working code map)

| Stage | Codes |
|---|---|
| At-risk population | menstruation, pregnancy, high activity, restricted diet, blood donation, low income, CKD, heart failure, chronic blood loss |
| Symptom / screening encounter | R53.83 fatigue · R42 dizziness · L65.9 hair loss · Z34.01 pregnancy supervision · Z13.0 blood-disorder screening |
| Initial labs (CPT) | 82728 ferritin · 83540 iron · 83550 iron-binding capacity · 84466 transferrin |
| Diagnosis | D50.0 / D50.8 / D50.9 iron-deficiency anemia; low ferritin *without* anemia tracked separately |
| Treatment | J1756 iron sucrose · J1439 ferric carboxymaltose · Q0138 ferumoxytol · 96365 / 96372 administration |

Codes are an analytical map. They do not imply coverage or payment.

## Hypotheses

1. **Undetected early deficiency:** many people have low iron stores without anemia.
2. **Segment concentration:** need concentrates in menstruating women, highly active women and people with symptoms or risk factors.
3. **Workflow friction:** patients face repeat visits, delays, access limits or OOP cost before iron testing.
4. **Hybrid adoption:** home screening followed by confirmatory lab testing is the strongest model.
5. **Different channels by segment:** consumers and athletes self-pay; lower-income groups need subsidised or payer access; pregnancy, CKD and heart failure need clinician oversight.
6. **Value depends on placement:** value comes from improving the decision to seek care, not from standalone diagnosis.

## Approach

| Source | Role | Output |
|---|---|---|
| NHANES 2017–Mar 2020 | Measured ferritin, hemoglobin, CRP, iron panel, demographics, questionnaire segments | Size and profile of low-ferritin populations, including low ferritin without anemia |
| MEPS 2023 | Utilization, insurance, setting, expenditures, OOP, access barriers | Where patients receive care and who faces affordability barriers |
| Synthea | Synthetic longitudinal encounters, conditions, observations, medications, payers | Code-level patient journey and workflow placement |

Sources are **not joined at the person level**. Findings are combined at the segment, workflow and
scenario level. Real data, synthetic records, assumptions and recommendations are labeled separately
throughout.
