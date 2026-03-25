# Gold CFD Lab — Project Rules

## North Star
R-multiple (return per unit risk). Same as EA Trading Lab.

## Philosophy
Boring = effective. Data first, always. No feature without proof.

## Instruments
- XAUUSD (Gold)
- US30 (Dow Jones)
- NAS100 (Nasdaq)
- DAX40 (GER40/DE40)

## Status
Phase 1 — Character study. No configurations locked yet.

## Key Questions (answer before building anything)
1. Does MA crossover produce positive expectancy on each instrument?
2. What timeframe performs best per instrument?
3. What SL/TP sizing works — fixed points or ATR-based?
4. Does session/day-of-week scoring apply?
5. What is the float-then-win character per instrument?

## Stack
- MQL5 EA — same base as EA Trading Lab
- Supabase — separate project (gold-cfd-lab)
- Agent — separate brain
- Dashboard — separate Vercel deployment
- GitHub: https://github.com/lusa8o8/gold-cfd-lab.git

## Rules
1. Never guess. Data first.
2. No cross-contamination with EA Trading Lab research.
3. ATR-based SL/TP until data proves fixed sizing works.
4. Same 36-field CSV logging standard as EA Trading Lab.
