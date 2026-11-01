---
name: awp
description: Build an internal-audit work program (AWP) workbook in the house format from a JSON spec, generate a blank AWP template, or export the spec from an existing AWP. Use whenever the user asks for an audit work program, AWP, RCM / walkthrough / testing workbook for an internal audit, or mentions skill-awp.
---

> In this repo the document below is `SKILL.md` and the builder is `scripts/skill-awp.py` (relative to this folder). Where the text says `python skill-awp.py ...`, run `python3 <skill-folder>/scripts/skill-awp.py ...`.

# skill-awp - internal-audit work program builder (two-file edition)

This skill consists of exactly two files: **skill-awp.md** (this document - instructions, layout, spec schema, content guide) and **skill-awp.py** (the builder script - the only way the workbook is written). Nothing else is required. Read Part 1 first; Parts 2-5 are the references.



# PART 1 - SKILL INSTRUCTIONS

# IA work program (AWP) builder

## What this skill produces
One workbook, identical structure and formatting every time, built only through `skill-awp.py` from a JSON spec:

| Sheet | Content |
|---|---|
| `Scope` | Key processes and the indicative areas of focus (from the engagement scope), with "Covered?" |
| `A` | Index: client / process / audit period (the only place they are typed - every other sheet references it), sign-off fields, links to A100 / A200 / A300 / DA |
| `A100` | Risk and control matrix: sub-process, risk, control no. (cross-reference to the walkthrough sheet), finding for design effectiveness, audit strategy (the test steps), testing result, WP ref |
| `A200` + `A201…` | Walkthrough index and one sheet per sub-process: background, activities with controls (performed by, frequency, control ref, control, owner, classification, type, DE finding, document to sight) and the walkthrough questions for the session (question, why we ask, documents to request, interviewee, response, control ref) |
| `A300` + `A301…` | Testing index and one sheet per test: objective, basis of selection, population, sample size, source, audit steps, work-done table (sample detail columns, one column per step, exceptions and remarks), notes, findings, conclusion |
| `DA` | Data-analytics plan: analytic, data source, what it identifies, test it feeds, result, status |

The series letter (`A`, `E`, …) is a spec setting. Numbering is automatic (A201…, A301…).

## Two ways to run it - pick by what Copilot can do
- **Mode 1 (Copilot can run Python):** the model writes the spec, runs `python skill-awp.py build spec.json "<output>.xlsx"`, verifies and delivers the workbook.
- **Mode 2 (no code execution):** the model's only deliverable is the complete spec JSON (saved or pasted as `spec.json`); anyone with Python 3 and openpyxl then runs `python skill-awp.py build spec.json "<output>.xlsx"` and gets the identical workbook. The content work is the same; nothing about the format depends on the model.
Before the first real use, run `python skill-awp.py selftest` once (prints SELFTEST PASSED and builds a template) - if that passes, the environment is proven and the only variable left is content. `python skill-awp.py template "AWP template.xlsx" --tests 12` gives the blank template at any time.

## Workflow
1. **Collect the engagement material** that exists: scope / engagement letter, prior-year report and AWP, kick-off minutes, SOPs, org chart, system list. If nothing exists, go straight to step 6 with `template_spec()` - the skill must still deliver a complete, consistently formatted template.
2. **Scope sheet first.** One row per key process with 2-6 indicative areas of focus written as "Check that …" sentences (see Part 4). Everything downstream maps back to these.
3. **Sub-processes and walkthroughs.** Decide the sub-process list (usually 4-8: control environment first, then the operating cycle in order, reconciliations last). For each, write the background, the activities with their controls (one control reference per control, `A201-1`, `A201-2` …) and 5-16 walkthrough questions with the reason for asking and the documents to request. Prior-year observations become questions and "why we ask" text.
4. **Risk and control matrix.** One row per risk; risk text states what could go wrong AND the consequence; control no. cross-references the walkthrough control(s); audit strategy carries the test steps ("Test n: title / Check that: / 1. …") or "Refer to Test n"; WP ref points to the test sheet. Prior-year findings and management commitments go into the DE-finding cell as context.
5. **Tests.** One sheet per test (10-15 is typical). Objective, basis of selection, population (and its source listing), sample size with the "or all if the population is smaller" rule, source documents, numbered audit steps, and the work-done table columns that fit the test (sample identifiers + the attributes the steps need). The number of step columns equals the number of numbered audit steps.
6. **DA plan.** For each test that uses a listing, state the analytic (what is compared with what), the listings needed, what an exception looks like and which test it feeds. Status = Planned.
7. **Write the spec JSON** (Part 3) and build: `python skill-awp.py build spec.json "<Client> IA FY<yy>_<Process>.xlsx"`.
8. **Verify** (mandatory): open the file; every cross-reference (control no., WP ref, "Refer to Test n", feeds) points to a sheet / control that exists; every scope area is covered by at least one RCM row; every RCM row has an audit strategy and WP ref; every test has steps and a work-done table whose step count matches; no `[placeholder]` left where material existed; header formulas resolve. Fix the spec and rebuild - never patch cells by hand.
9. **Report** in a few lines: file location, counts (sub-processes, controls, risks, tests, analytics), what was drawn from which source, what is still placeholder and the questions for the client.

## Rules
- The spec is the single source; the workbook is generated. Changes are made in the spec and rebuilt (export an existing AWP with `python skill-awp.py export existing.xlsx spec.json` to get its spec).
- Write in complete sentences, past/present tense as the house examples; name roles, systems, documents and thresholds; no bullet fragments in risk and control cells.
- Audit steps are numbered and each one is checkable with a document. Steps the team cannot evidence are not steps.
- Never invent client facts. Where the material is silent, leave the `[placeholder]` and list it as an open question in the report.
- Sample sizes follow the firm's sampling guidance; always carry "or all if the population is smaller" where it applies.
- Keep prior-year observations visible: in the DE-finding cell of the RCM, in the walkthrough "why we ask", and in the test objective ("This test also follows up on prior-year Observation n").

## Files
- `skill-awp.py` - `build` / `template` / `export` / `selftest`. Commands:
  - `python skill-awp.py template "AWP template.xlsx" --tests 12` - blank template with [placeholders]
  - `python skill-awp.py build spec.json "AWP.xlsx"` - workbook from a spec
  - `python skill-awp.py export "Existing AWP.xlsx" spec.json` - spec from an existing AWP in this layout (reuse a finished engagement)
  - `python skill-awp.py selftest` - proves the environment works
- Requires Python 3 with `openpyxl` only (`pip install openpyxl`).

# PART 2 - LAYOUT AND FORMATTING (enforced by skill-awp.py)

# AWP layout and formatting (enforced by skill-awp.py)

## Global
- Font Arial 8 everywhere. Gridlines off. Tab colour 92D050 (Scope tab black).
- Row 1, last used column: the sheet reference in a yellow (FFFF00) box, bold, centred, double border.
- A3:B5: `Client`, `Process`, `Audit period` (RCM uses `Client:` / `Process:` / `Review period:`). Values typed on the index sheet only; every other sheet uses `='A'!B3` … so a change propagates.
- Index sheet also carries `Prepared by:` / `Date:` (row 3) and `Reviewed by:` / `Date:` (row 5) in D-G when `signoff` is true.
- Cross-references (control numbers, WP refs, index refs) are bold red (FF0000), centred.
- Column headers: grey fill D9D9D9, bold, centred (left for text-heavy columns), wrapped, thin borders.
- Text cells: wrapped, top-aligned, thin borders; row height sized to the longest text in the row (11.25 pt per line).

## Scope
Columns `No | Key Process | Indicative area of focus | Covered?`. Header fill black with white bold text; `Covered?` header fill 4BACC6. One row per area; `No` and `Key Process` merged down the key process. Widths 6 / 49 / 80 / 42.

## Index sheets (A, A200, A300)
Row 7: title (`Index`, `Process walkthrough`, `Testing`) bold with a bottom border in B, `Ref` in the ref column. Items every second row from row 9: number centred in A, title in B (width 64), ref bold red in the ref column (G for A and A200, E for A300).

## A100 - Risk and control matrix
Header row 7: `S/N | Sub-process | Risk | Control No. | Finding for Design Effectiveness | Audit Strategy | Testing Result | WP Ref` (height 30.75). Section rows merged A:H, fill DCE6F1, bold (`1. Overall Control Environment`). Data rows: S/N centred; sub-process, risk, DE finding, audit strategy, testing result left-wrapped; control no. and WP ref bold red centred. Freeze panes C8. Widths 14.4 / 44.9 / 69.6 / 15.9 / 67.3 / 83.1 / 70.9 / 13.6.

## A201… - Walkthrough
- Row 7 merged A:K: `Subprocess title: <title>` - fill 808080, white bold.
- Row 8 merged A:K: `Background:` + blank line + narrative (process, systems, people, changes in the period; prior-year context).
- Row 9 header: `No. | Activity | Performed By | Frequency | Control Reference No. | Existing controls / mitigating measures | Control Owner | Control Classification | Control Type | Finding for design effectiveness | Walkthrough Document`.
- Sub-section rows merged A:K, bold, no fill (`1.1 Policies and procedures and Delegation of Authority`). Activity rows numbered continuously across sub-sections; control refs `<sheet>-<n>` bold red; a row may simply cross-refer (`Please refer to <A302> …`).
- Blank row, then merged A:K band (808080, white bold) `Walkthrough questions for the team lead (…)`, header `No. | Question (B:D) | Why we are asking, including the prior-year context (E:F) | Documents to request during the session (G:H) | Proposed interviewee | Response noted during the walkthrough | Control Reference No.`; question rows keep the same merges.
- Freeze panes A10. Widths 12.6 / 42.6 / 19 / 19.1 / 16 / 50.4 / 16.1 / 16.6 / 12.9 / 59.1 / 16.1.

## A301… - Test sheet
- Row 7: `Test n` in A and the title in B on an 808080 band with white bold text across the table width.
- Rows 9-19 (every second row): `Objective:`, `Basis of Selection:`, `Population:`, `Sample Size:`, `Source:`, `Audit Steps:` - label bold in A, text merged B:I.
- Row 21: `Work done:` in A; detail-title header merged over the sample-detail columns (fill B7DEE8); `Work Done` merged over the step columns (fill 92D050); `Remarks` over the last column (B7DEE8).
- Row 22: `S/N`, the detail column names (B7DEE8), step numbers 1..n (92D050), `Exceptions and remarks` (B7DEE8); height 45.
- Rows 23+: S/N 1..n with bordered empty cells (height 33.75). Computed columns carry a formula per row (e.g. days between dates, rent x 3, variance %).
- Then `Notes:` / `Findings:` / `Conclusion:` every second row (defaults `Nil`, `Nil`, `To be concluded on completion of fieldwork.`). During fieldwork: notes numbered N1, N2 … referenced from the remarks column; conclusion `No exceptions noted.` / `Exceptions noted - refer to Findings.`
- Freeze panes C23. Widths A 20.6, B 7.6, detail columns 14-42 by header length, step columns 8.9, remarks 47.4.

## DA
Row 7 `Data analytics` / `Ref`. Header row 9: `S/N | Analytic | Data source | What the analytic is designed to identify | Feeds | Result | Status`. `Feeds` bold centred (test refs, newline-separated when several). Note row merged A:G below the table. Widths 13.6 / 64 / 18.9 / 60 / 9.7 / 30 / 11.



# PART 3 - SPEC SCHEMA (what the model writes)

# Spec schema (JSON)

Every text field is optional. Missing text becomes a `[placeholder]` in the workbook so the template is always complete. `prefix` is the workpaper series letter. Refs (`A201`, `A301`) are assigned automatically in list order unless given.

```json
{
  "prefix": "A",
  "client": "Singapore Cruise Centre Pte Ltd",
  "process": "Commercial Leasing",
  "period": "1 October 2025 to 30 September 2026",
  "signoff": true,                      // Prepared by / Reviewed by / Date fields on the index sheet
  "prepared_by": "", "reviewed_by": "",

  "scope": [
    {"no": 1, "key_process": "Overall control environment",
     "areas": ["Check that policies and procedures ... are formalised, complete, version-controlled and approved ...",
               "Check that a Delegation of Authority has been established ..."],
     "covered": "Yes"}
  ],

  "rcm": {"sections": [
    {"title": "1. Overall Control Environment",
     "rows": [
       {"sn": 1, "sub_process": "Policies and procedures",
        "risk": "Policies and procedures ... may not be formalised ... This may result in ...",
        "control_no": "A201-1",                      // one or more, newline-separated; "-" if none
        "de_finding": "To be concluded after the walkthrough.\n\nIn the prior year we noted ...",
        "audit_strategy": "Test 1: Policies and procedures and Delegation of Authority\nCheck that:\n1. ...\n2. ...",
        "testing_result": "",                        // filled during fieldwork
        "wp_ref": "A301"}
     ]}
  ]},

  "walkthroughs": [
    {"ref": "A201", "title": "Overall control environment",
     "index_text": "Overall control environment, covering policies and procedures, the Delegation of Authority, segregation of duties and Voyager access rights",
     "background": "Singapore Cruise Centre ... (process, systems, people, changes in the period)",
     "sections": [
       {"title": "1.1 Policies and procedures and Delegation of Authority",
        "activities": [
          {"no": 1, "activity": "The Manager (Commercial Leasing) prepares and updates the SOP ...",
           "performed_by": "Manager (Commercial Leasing)", "frequency": "As and when required",
           "control_ref": "A201-1",                  // omitted -> assigned automatically when a control is given
           "control": "The SOP is reviewed and approved by the Head of Commercial Leasing ...",
           "owner": "Head of Commercial Leasing", "classification": "Preventive", "type": "Manual",
           "de_finding": "", "document": "Latest SOP, cover page and amendment history"},
          {"no": 3, "refer_to": "Please refer to <A302> for the segregation of duties matrix."}   // activity row that only cross-refers
        ]}
     ],
     "questions_title": "Walkthrough questions for the team lead (to be used during the walkthrough session on 26 or 27 October 2026)",
     "questions": [
       {"no": 1, "question": "Which version of the SOP is in force ...?",
        "why": "In the prior year we noted that Version 7 ...",
        "documents": "The latest SOP in full, the cover page and the amendment history",
        "interviewee": "Head of Commercial Leasing", "response": "", "control_ref": "A201-1"}
     ]}
  ],

  "tests": [
    {"ref": "A301", "no": 1, "title": "Policies and procedures and Delegation of Authority",
     "objective": "To check that ...",
     "basis": "Not applicable, as all policies and the Delegation of Authority are reviewed",
     "population": "Not applicable", "sample_size": "Not applicable",
     "source": "Policies, SOPs and the Delegation of Authority",
     "steps": "Test 1: Policies and procedures and Delegation of Authority\nCheck that:\n1. ...\n2. ...",
     "detail_title": "Policies and procedures",                          // header over the sample-detail columns
     "detail_columns": ["Document", "Version or reference", "Date approved", "Approved by", "Communication to staff"],
     "detail_formulas": {"Days from lease end to refund": "=IF(AND(ISNUMBER(E{r}),ISNUMBER(H{r})),H{r}-E{r},\"\")"},  // optional, {r} = row
     "n_steps": 6,                 // step columns; defaults to the number of numbered lines in "steps"
     "n_rows": 6,                  // sample rows (S/N 1..n)
     "rows": [{"values": ["...", "..."], "steps": ["Yes", "Yes"], "remarks": ""}],   // optional pre-filled work done
     "notes": "Nil", "findings": "Nil", "conclusion": "To be concluded on completion of fieldwork."}
  ],

  "da": {
    "analytics": [
      {"sn": 1, "analytic": "Completeness of billing. For each month, the active leases ... are compared with the invoices issued.",
       "source": "Lease listing and invoice listing",
       "identifies": "An active lease with no fixed rent invoice in a month indicates unbilled revenue ...",
       "feeds": "A308", "result": "", "status": "Planned"}
    ],
    "note": "The analytics are to be run on the population listings requested in advance of fieldwork ..."
  }
}
```

## Template spec
`python skill-awp.py template out.xlsx --tests N` builds the blank template with `[placeholders]` describing what belongs in each cell (2 walkthroughs, N tests, 3 analytics; add more by building from a spec).

## Export
`python skill-awp.py export existing.xlsx spec.json` reads an AWP built in this layout (including hand-finished ones) back into a spec, so a completed engagement can be reused as the starting point for the next one.



# PART 4 - CONTENT GUIDE (how to write each element)

# Content guide - how to write each element (house examples from the commercial-leasing AWP)

## Scope - indicative areas of focus
Each line is a sentence beginning "Check that …" (or "Assess whether …") that names the control objective and, where relevant, the system, document or period-specific event.
> Check that security deposits and banker's guarantees are collected in accordance with the lease agreements before the premises are handed over to the tenant.
> Check that incoming tenant fit-out and outgoing tenant make-good activities are monitored, with particular attention to the exit from the Old Harbourfront terminal in July 2026 and the new leases at the new terminal.

Group 2-6 lines under each key process; order: control environment → operating cycle in sequence → receivables / collections → reconciliations.

## Walkthrough background
One paragraph on the business and the process (what, where, which system, who - team sizes matter for segregation of duties), one paragraph on changes in the period, one on prior-year points that the walkthrough must confirm.
> Singapore Cruise Centre Pte Ltd ("SCCPL") manages and operates ferry terminals and a cruise terminal in Singapore, and leases the commercial space within the terminals to retail, food and beverage, telecommunications, vending and advertising tenants. In July 2026 SCCPL ceased operating from the Old Harbourfront terminal and commenced operations at the new terminal … The Commercial Leasing ("CL") department, which has two staff, manages the tenancies …
> In the prior year (FY2023/24) we noted that the Property Management SOP was incomplete and that the controls over Voyager access rights needed to be strengthened. Management committed to …

## Activity and control (walkthrough rows)
- Activity: who does what, when, in which system, with which document - present tense, one activity per row.
> When a unit becomes vacant or new units become available, the Manager (Commercial Leasing) compiles a list of target companies against financial, non-financial and other criteria, and the Head of Commercial Leasing selects the companies to approach.
- Control: what prevents or detects the risk and how it is evidenced.
> The Delegation of Authority is approved by the CEO or the Board. In the prior year, contracts above S$500,000 were approved by the CEO or Executive Director, contracts between S$350,000 and S$500,000 by the Head of Finance, and contracts below S$350,000 by the Head or Senior Manager of Commercial Leasing. Any rent below the approved budget required the approval of the CEO.
- Performed by / Control owner: role titles, not names. Frequency: `As and when required`, `Monthly`, `Quarterly`, `One-off`. Classification `Preventive` / `Detective`; Type `Manual` / `IT`.
- Walkthrough document: the exact evidence to sight (`Access request forms and the joiner, mover and leaver listing for the period`).
- A row may cross-refer instead of describing (`Please refer to <A302> for the segregation of duties matrix.`).

## Walkthrough questions
Open questions that make the interviewee describe the step; the "why" states the risk, the prior-year point or the change; documents are specific.
> Q: Could you walk us through the current Delegation of Authority for lease pricing, tenant selection, signing of agreements, rent relief, waivers, credit notes, refunds and write-offs?
> Why: The prior-year thresholds were S$500,000 for the CEO or Executive Director … We need to confirm whether the limits have changed and whether the approvals for the new terminal leases were obtained at the right level.
> Documents: The approved Delegation of Authority and the approval papers for the five largest new leases.
Interviewee: role. Response: blank (completed in the session). Control ref: the control the question tests.

## Risk (RCM)
"X may not / may be … This may result in …" - name the specific failure and the consequence; mention structural causes (team of two, system migration, terminal move).
> The Commercial Leasing team consists of two staff and the Finance team supporting the process is also small. The same person may therefore be able to record, approve and reconcile transactions, so that errors or unauthorised transactions are not detected on a timely basis.

## Finding for design effectiveness (planning stage)
`To be concluded after the walkthrough.` followed, where relevant, by the prior-year observation and management's commitment:
> In the prior year we raised Observation 2.2 (Moderate). Three of the five new leases sampled had no insurance policy on file and one of the five renewed leases had insufficient coverage. Management committed to track insurance submissions and coverage in the new Yardi system.

## Audit strategy / audit steps
Header line `Test n: title`, then `Check that:` and numbered steps; each step names the attribute and the document that proves it. Where a risk is covered by another test: `Refer to Tests 4 and 5.` or `Refer to Test 1.` followed by the specific step numbers.
> Test 6: Expired and terminated leases
> Select ten expired or terminated leases, or all such leases if the population is smaller, with emphasis on the Old Harbourfront exit, and check that:
> 1. The notice of expiry or termination was given in accordance with the Tenancy Agreement, and any early termination penalty was imposed or its waiver approved.
> 2. A joint inspection was carried out and the make-good items were recorded on the checklist and closed before the deposit was refunded.
> 3. …

## Test sheet fields
- Objective: `To check that …` (one sentence; add `This test also follows up on prior-year Observation n.` where it does).
- Basis of selection: `Haphazard, with emphasis on …` / `All …` / `Not applicable, as …`. Name what the emphasis is (largest, non-standard, transition month).
- Population: what and per which listing (`Invoices issued during the period per the invoice listing`).
- Sample size: `Twenty-five across three months, including …` / `Ten, or all new leases if the population is smaller` / `All users and three months`.
- Source: documents and listings used.
- Detail columns: the identifiers and attributes the steps need (invoice number, date, tenant, unit, period, charge type, amount; or user name, department, group, status, created, last login). Computed columns get a formula.
- Notes / Findings / Conclusion defaults: `Nil` / `Nil` / `To be concluded on completion of fieldwork.`

## DA plan rows
Analytic = what is compared with what; source = listings; identifies = what an exception looks like; feeds = the test sheet(s).
> Security deposits held compared with three months of rent for each lease. | Lease listing and security deposit listing | A deposit below three months of rent indicates a shortfall. A deposit held for more than 90 days after the lease ended indicates a delayed refund. | A312, A306

## Numbering
Sub-processes 1..n; walkthrough sheets A201..; controls `A201-1`…; sections `1.1`, `1.2`; activities numbered continuously within a sheet; tests 1..n with sheets A301..; RCM S/N continuous across sections; scope No per key process.

## Sizing conventions seen in practice
New / renewed / terminated items: 5-10 (or all if fewer); transactions: 25 across three months; monthly controls: 3 months incl. the period-end or a transition month; all users for access reviews; full listing reconciled + 10 vouched for balances.



# PART 5 - RUNNING IT IN COPILOT

The workbook is generated by `skill-awp.py`; the model's job is to write the spec (content) from the engagement material and then run the builder, or hand over the spec. It needs a Copilot surface that can run Python (only `openpyxl` is required) and save a file - or, failing that, a PC that can run the script. Confirm with your Copilot admin which applies; features change.

## Option A - GitHub Copilot (Enterprise) in VS Code / Copilot CLI (recommended)
1. Put `skill-awp.md` and `skill-awp.py` in the engagement folder (or a skills folder your Copilot reads).
2. `pip install openpyxl`.
3. Pick a Claude model, open agent mode, and prompt, for example:
   > Follow skill-awp.md. Scope letter: `01. Planning/<scope>.docx`; prior-year report: `06. References/<report>.pdf`; kick-off minutes: `00. Minutes/`. Build the AWP for <client> / <process> / <period> into `04. AWP/` using skill-awp.py.
   With no material: > Follow skill-awp.md and give me the blank AWP template with 6 sub-processes and 12 tests.
4. Ask for the verification list (Part 1, workflow step 8) and the open questions before you accept the file.

## Option B - Microsoft 365 Copilot chat / Copilot Studio agent
1. Attach `skill-awp.md` and `skill-awp.py` (or paste `skill-awp.md` as the agent instructions and add `skill-awp.py` as a knowledge file); enable the code-interpreter / Python capability and file download.
2. Prompt as above, adding "save skill-awp.py to the sandbox before building".
3. If the sandbox does not keep files between turns, paste the script into the first message and have the agent save it to disk. Formulas calculate when Excel opens the file; no recalculation step is needed.

## Option C - chat without code execution (Mode 2 - still fully usable)
The model drafts the content as the complete spec JSON (ask for it as a code block or a saved file). Save it as `spec.json` next to `skill-awp.py` on any PC with Python 3 and openpyxl and run `python skill-awp.py build spec.json "AWP.xlsx"`.

## First-run checklist (no trial and error)
1. `python skill-awp.py selftest` -> SELFTEST PASSED.
2. `python skill-awp.py template "AWP template.xlsx" --tests 12` and open it - this is exactly what every build will look like, with [placeholders] where content goes.
3. Give Copilot the two files and the engagement documents; ask for the spec JSON first and review the content (that is where judgement is needed), then build.
4. Run the verification list (Part 1, step 8) before sharing.

## Prompt pattern (keep the steps separate)
1. "Read the scope / prior-year report / minutes and propose the key processes, sub-processes and tests (as a table)."
2. "Draft the walkthrough activities, controls and questions for each sub-process."
3. "Draft the RCM rows and the audit steps; map each scope area to a risk and each risk to a test."
4. "Write the spec JSON, build the workbook with skill-awp.py, run the verification list and give me the open questions."
