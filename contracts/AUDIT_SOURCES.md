# Audit Sources (Muscle Memory)

Use these as mandatory first reads before contract audits/hardening:

1. ETHSkills OpenClaw Hub (master router)
- https://github.com/clawdbotatg/ethskills/blob/master/openclaw-skill/SKILL.md

2. EVM Audit Master (deep audit routing)
- https://raw.githubusercontent.com/austintgriffith/evm-audit-skills/main/evm-audit-master/SKILL.md

## Required Workflow
1. Read both master files.
2. Select relevant domain checklists (general, precision-math, access-control, signatures, dos, etc.).
3. Produce findings files in `contracts/audits/`.
4. Synthesize into `contracts/AUDIT-REPORT.md` with GO/NO-GO.
