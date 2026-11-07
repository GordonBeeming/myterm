# Domain docs

This repo uses a single domain context: one root `GLOSSARY.md` and architectural decisions in `docs/adr/`.

## Before exploring

Read `GLOSSARY.md` and any ADRs relevant to the work. If an expected document does not exist, continue without treating its absence as a setup failure. Domain-modeling creates glossary entries and ADRs when terms or decisions need recording.

## Use the agreed language

Use the glossary's terms in issue titles, explanations and tests. When a term is ambiguous or conflicts with the glossary, clarify its meaning before recording a change. Keep glossary entries about domain concepts; put implementation decisions and their tradeoffs in the relevant ticket or ADR.

## Flag decision conflicts

If proposed work contradicts an ADR, identify the decision and explain the conflict before changing the behavior. Preserve the reason for the existing decision when considering whether to replace it.
