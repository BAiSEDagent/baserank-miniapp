# BaseRank Kanban

## In Progress
- [ ] Featured submission handoff
  - [ ] Docs-linked Google form is unpublished; get current submission endpoint from Base Build/support
  - [ ] Submit BaseRank for featured once endpoint is confirmed
- [ ] Mainnet deployment pipeline completion
  - [ ] Add deploy tooling (Foundry or equivalent) in-repo
  - [ ] Deploy `BaseRankMarket` to Base mainnet
  - [ ] Set `NEXT_PUBLIC_MARKET_ADDRESS` in Vercel
  - [ ] Verify end-to-end: connect → stake → sponsored attempt → fallback
- [ ] Featured readiness polish (Product Guidelines)
  - [ ] Empty states for non-market tabs
  - [ ] Copy sweep for client-agnostic language
  - [ ] Profile utility panel polish

## Todo
- [ ] Base notification compliance implementation
  - [ ] Post-first-success opt-in prompt (not first load)
  - [ ] Add notifications webhook receiver route (`/api/webhook/notifications`)
  - [ ] Return fast success response and process token async
  - [ ] Notification sender utility with `${username}` personalization support
  - [ ] Enforce payload constraints (title <=32, body <=128, targetURL same-domain)
  - [ ] Add frequency guardrails (well below 100/day cap)
- [ ] Positions tab empty state
  - [ ] Centered icon + text: "No active predictions"
  - [ ] CTA: "Explore Markets" routes to Markets tab
- [ ] Profile tab utility state
  - [ ] Show avatar + basename/username
  - [ ] Show wallet identity in user-friendly format
  - [ ] Show USDC balance on Base
  - [ ] If zero balance, prompt funding message
- [ ] Product guideline compliance pass
  - [ ] Ensure load indicators for all async actions
  - [ ] Ensure no dead ends on any tab state
  - [ ] Keep onboarding short and clear (<=3 screens)
  - [ ] Verify user profile visible in app chrome
- [ ] Contract confidence gate before mainnet
  - [ ] Full adversarial test pass (access control, payout conservation, claim correctness)
  - [ ] Resolution abuse/griefing scenarios
  - [ ] Final risk register + mitigations

## Blocked
- [ ] Mainnet deploy blocked on deploy key availability on this host (`DEPLOYER_PRIVATE_KEY`)
- [ ] Safe fee recipient final address confirmation

## Done
- [x] Global Cash App-style UI overhaul shipped
- [x] Gasless-first scaffold implemented with paymaster proxy + fallback
- [x] `PAYMASTER_URL` wired in Vercel
- [x] Build and lint green; production deploy active
