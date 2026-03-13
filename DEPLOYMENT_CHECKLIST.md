# BaseRank Deployment Checklist

## Freeze
- [ ] Logic freeze remains `d24e64e`
- [ ] Repo/operator polish remains `f78bb7a`
- [ ] No unreviewed logic drift after freeze

## Contracts
- [ ] `contracts/src/EventRegistry.sol`
- [ ] `contracts/src/TierMarket.sol`
- [ ] `contracts/src/BatchClaimer.sol`
- [ ] `forge test` → 149/149 PASS

## Frontend / API
- [ ] `src/app/page.tsx`
- [ ] `src/app/api/activity/route.ts`
- [ ] `src/app/api/positions/route.ts`
- [ ] `src/lib/contracts/BatchClaimerABI.ts`
- [ ] `npm run build` PASS
- [ ] `npm run lint` PASS (warnings reviewed)

## Security / Hygiene
- [ ] `npx gitleaks detect --source . --no-git` PASS
- [ ] `npm audit --audit-level=high` PASS
- [ ] `.gitignore` excludes generated contract/build artifacts

## Production Environment
- [ ] `NEXT_PUBLIC_EVENT_REGISTRY_ADDRESS` set
- [ ] `NEXT_PUBLIC_BATCH_CLAIMER_ADDRESS` set
- [ ] all 6 TierMarket addresses set
- [ ] `NEXT_PUBLIC_ACTIVE_EVENT_ID` set
- [ ] `PAYMASTER_URL` set
- [ ] no quoted / malformed values in Vercel

## UI Verification
- [ ] footer shows EventRegistry address
- [ ] footer shows BatchClaimer address
- [ ] results view shows claim preview from event-tier positions
- [ ] claim CTA calls BatchClaimer path
- [ ] no V2 pool/position surface remains on critical paths

## Live Transaction Smoke Test
- [ ] connect wallet
- [ ] approve USDC to one TierMarket
- [ ] place one prediction
- [ ] position appears in Track tab
- [ ] claim preview appears when appropriate

## Ops / Resolution
- [ ] active event ID matches EventRegistry
- [ ] Wednesday cadence confirmed
- [ ] official leaderboard source verified before resolution
- [ ] operator runbook available

## Trust Assumptions Disclosed
- [ ] owner/admin keys remain trusted
- [ ] resolver/governance flow remains trusted operationally
- [ ] `claimFor(user)` permissionless but non-custodial

## Deferred Hardening Logged
- [ ] third-party audit
- [ ] timelock
- [ ] optional pause path
- [ ] gas profiling
- [ ] formal invariant verification
