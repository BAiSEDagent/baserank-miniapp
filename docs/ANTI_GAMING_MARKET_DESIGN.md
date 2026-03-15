# BaseRank — Anti-Gaming Market Design Memo

## Problem
As Base Builder Codes, Dune dashboards, and public app analytics become more legible, users may be able to infer effective leaderboard placement before markets lock.

If users can observe the outcome with high confidence before lock, the market becomes gameable:
- late-entry near-certainty betting
- artificially high win rates
- lower-quality price discovery
- reputation damage (market feels solved instead of predictive)

## Core Rule
**If users can observe the effective outcome before lock, the market is compromised.**

This is not just a competition/moat problem.
It is a **market integrity** problem.

---

## What Changes the Risk
Public data surfaces now include or may soon include:
- Builder Code attribution
- Dune dashboards over builder-code-linked activity
- Base leaderboard/discovery surfaces
- app-level metrics like addresses, tx count, fees, and rolling windows

These may not replicate the exact official weekly leaderboard at all times, but they can expose enough signal to make certain markets low-information or near-deterministic late in the cycle.

---

## Unsafe Market Shape
These markets become weak first:
- “Who is #1 this week?”
- “Who is top app right now?”
- any market whose outcome is increasingly visible before lock through public metrics

### Why unsafe
By the final stretch of the window, users may be able to:
- monitor standings
- only enter when certainty is high
- avoid uncertain entries entirely

That produces win-rate distortion rather than real prediction.

---

## Safer Market Shapes
These are harder to game and preserve predictive value:

### 1. Future interval markets
Examples:
- Who will finish #1 by next Wednesday?
- Which app will enter Top 5 over the next 7 days?
- Which app gains the most rank over the next period?

### 2. Relative markets
Examples:
- App A vs App B next period
- Which of these 3 apps finishes higher next window?

### 3. Threshold / milestone markets
Examples:
- Will app X exceed N transacting addresses next week?
- Will app Y enter Top 10 by next snapshot?

### 4. Momentum markets
Examples:
- Biggest mover over next interval
- Largest weekly fee growth
- Largest weekly tx growth

These are better because they force the bet to be about **future movement**, not a mostly-known present state.

---

## Design Defenses

### A. Lock earlier
This is the cleanest defense.
If public analytics make the outcome too legible late in the cycle, move lock earlier.

**Rule:** lock before the decisive data becomes broadly observable.

### B. Bet on future interval, not current interval
Avoid framing markets around outcomes users can infer from already-published data.

Good:
- future ranking changes
- next interval outcome

Bad:
- current week standing when the week is already mostly known

### C. Shorten late betting window
Do not leave markets open through the highest-certainty phase.

### D. Add operational risk controls on late concentration
Possible controls:
- lower max stake near lock
- flag heavy late concentration
- limit size near end of epoch

These are secondary defenses, not substitutes for better timing design.

### E. Avoid relying on “mystery data” as moat
BaseRank should not depend on hidden placement information.
The defensible layer is:
- market structure
- timing
- resolution credibility
- UX / distribution / social loop

---

## Recommended Immediate Policy

### Keep
- current event-tier architecture
- isolated pools by market/tier
- audited resolver/challenge/finalization flow

### Change
- treat “publicly legible ranking before lock” as a market-design red flag
- prefer future-interval and momentum-style markets over current-state markets
- revisit weekly lock timing if public builder-code analytics become widely used

---

## Market Integrity Checklist
Before launching any new market type, ask:

1. Can users observe the likely outcome before lock?
2. Is the market about future movement or current visible state?
3. Does the lock happen before public certainty spikes?
4. Could a rational user wait until late in the window and still get near-certain edge?
5. Would a public dashboard make this market trivial?

If answers indicate high late certainty, redesign the market.

---

## Product Conclusion
Builder-code analytics do not kill BaseRank.
But they do force us to move from:
- hidden-standings gambling

to:
- properly timed prediction markets on future outcomes.

That is a stronger product anyway.
