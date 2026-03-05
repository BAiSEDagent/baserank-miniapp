# BaseRank Build Log

Tracks build-by-build progress for fast recall and handoff.

## 2026-03-04

### Build: Global Cash App UI overhaul
- Scope: app-wide visual conversion to flat/brutalist fintech style (header, feed rows, bottom nav, modal consistency)
- Key changes:
  - removed glass/blur/shadow-heavy surfaces
  - converted leaderboard into flat full-width activity rows
  - hard separators and stronger typography hierarchy
  - bottom nav active/inactive contrast and badge pattern
- Validation: `npm run lint` ✅, `npm run build` ✅
- Deploy: `https://baserank-miniapp.vercel.app`

### Build: Paymaster scaffold + fallback
- Scope: gasless-first transaction architecture with resilient fallback
- Key changes:
  - added secure proxy route: `src/app/api/paymaster/route.ts`
  - wired EIP-5792 path via `useWriteContracts` (`wagmi/experimental`)
  - pass capabilities paymaster service url through local proxy (`/api/paymaster`)
  - fallback to standard `writeContract` on unsupported wallet / sponsorship failure
  - added UX copy: "Sponsored gas unavailable — using network fee"
- Validation: `npm run lint` ✅, `npm run build` ✅
- Deploy: `https://baserank-miniapp.vercel.app`
- Env set: `PAYMASTER_URL` configured in Vercel

### Build: Product polish pass (Featured Product Guidelines)
- Scope: eliminate dead-ends, improve empty states, and align with Base product UX guidance
- Key changes:
  - rebuilt first-load onboarding as full-screen high-contrast takeover with clear value prop + `Start Predicting` CTA
  - added Positions tab empty state with icon, explanatory copy, and `Explore Markets` CTA back to core flow
  - implemented Profile panel with avatar/name, smart wallet connected state, and live USDC balance check + zero-balance prompt
  - removed Farcaster-specific share language and replaced with client-agnostic confirmation copy
  - tightened modal spring choreography to `stiffness: 300, damping: 25`
- Validation: `npm run lint` ✅, `npm run build` ✅
- Deploy: `https://baserank-miniapp.vercel.app`

### Build: Notifications compliance scaffold (Base Featured)
- Scope: notification opt-in UX + webhook + payload guardrails
- Key changes:
  - added contextual post-success notification prompt (only after first successful prediction)
  - added utility: `src/lib/notifications.ts` to request native Base notification permission when supported
  - added webhook receiver: `src/app/api/webhook/notifications/route.ts`
    - designed for fast acknowledgment and deferred processing path
  - added payload utility: `src/lib/notification-payload.ts`
    - validates title/body length constraints
    - enforces same-domain target URL
    - includes `${username}`-compatible weekly resolution template
- Validation: `npm run lint` ✅, `npm run build` ✅
- Deploy: `https://baserank-miniapp.vercel.app`

### Build: Consistency pass (ops layout + welcome wow)
- Scope: eliminate dead-end ops route and align visual system across onboarding + ops
- Key changes:
  - rebuilt `/ops/checklist` with brutalist styling (flat rows, hard borders, high-contrast typography)
  - added sticky back navigation on ops page (`← Back to Markets`) plus persistent bottom nav shell
  - upgraded onboarding with premium motion and brand impact:
    - large-scale headline treatment
    - framer-motion staggered spring reveals
    - polished Base-blue glow accent
  - removed lingering blur styling from toast surface for flat design consistency
- Validation: `npm run lint` ✅, `npm run build` ✅
- Deploy: `https://baserank-miniapp.vercel.app`

### Build: Final compliance patch (assets + reconnect + disconnected states)
- Scope: close remaining Product Guideline gaps before Featured submission
- Key changes:
  - hard-set `reconnectOnMount` on `WagmiProvider` for clearer zero-click reconnect behavior
  - generated and added branded assets:
    - `public/assets/icon-1024.png` (1024x1024, solid background)
    - `public/assets/cover-1200x630.png` (benefit-focused cover)
  - updated `public/.well-known/farcaster.json` to point to branded icon/cover/splash assets + submission subtitle
  - added clean disconnected prompts in Positions/Profile tabs (`Connect Wallet`) instead of empty dead states
- Validation: `npm run lint` ✅, `npm run build` ✅
- Deploy: `https://baserank-miniapp.vercel.app`
