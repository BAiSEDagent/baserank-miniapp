'use client'

import { useEffect, useMemo, useState } from 'react'
import {
  useAccount,
  useChainId,
  useConnect,
  useDisconnect,
  useSwitchChain,
  useWriteContract,
  useWaitForTransactionReceipt,
  useEnsName,
  useEnsAvatar,
  useBalance,
} from 'wagmi'
import { parseUnits } from 'viem'
import { base } from 'wagmi/chains'
import { BetSheet } from '@/components/bet-sheet'
import { CountdownTimer } from '@/components/countdown-timer'
import Image from 'next/image'
import { requestBaseNotificationPermission } from '@/lib/notifications'
import { motion } from 'framer-motion'
import { TierMarketABI } from '@/lib/contracts/TierMarketABI'
import { candidateIdForKey } from '@/lib/candidate-id'
import { getEventTierConfig, type MarketKind, type TierKey } from '@/lib/event-tier'


const TARGET_CHAIN = base.id
const USDC_BASE = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913' as const
const MIN_STAKE_USDC = 0.01 // $0.01 minimum = 10000 in 6 decimals

function formatLastUpdate(lastUpdateMs: number | null) {
  if (!lastUpdateMs) return 'Last snapshot: —'
  const diffSec = Math.max(0, Math.floor((Date.now() - lastUpdateMs) / 1000))
  if (diffSec < 60) return `Last snapshot: ${diffSec}s ago`
  const m = Math.floor(diffSec / 60)
  if (m < 60) return `Last snapshot: ${m}m ago`
  const h = Math.floor(m / 60)
  const remM = m % 60
  return `Last snapshot: ${h}h ${remM}m ago`
}

type LeaderboardEntry = {
  rank: number
  projectId: string
  projectName: string
  appUrl: string
  weeklyTransactingUsers: string
  totalTransactions: string
  iconUrl: string
  tradeable?: boolean
}

function tierKeyFromSheetTier(tier: number): TierKey {
  if (tier === 1) return 'top10'
  if (tier === 2) return 'top5'
  if (tier === 3) return 'top1'
  throw new Error(`Unsupported tier selection: ${tier}`)
}

export default function Home() {
  const { address, isConnected } = useAccount()
  const chainId = useChainId()
  const { connect, connectors, isPending } = useConnect()
  const { disconnect } = useDisconnect()
  const { switchChain } = useSwitchChain()
  const { writeContractAsync, data: hash, isPending: isTxSending } = useWriteContract()

  const { isLoading: isConfirming, isSuccess: isConfirmed } = useWaitForTransactionReceipt({ hash })

  const { data: ensNameRaw } = useEnsName({ address, chainId: 1, query: { enabled: !!address } })
  const ensName = ensNameRaw ?? undefined
  const { data: ensAvatar } = useEnsAvatar({ name: ensName, chainId: 1, query: { enabled: !!ensName } })
  const { data: usdcBalance, isLoading: usdcLoading } = useBalance({
    address,
    token: USDC_BASE,
    chainId: base.id,
    query: { enabled: !!address },
  })

  const [activitySummary, setActivitySummary] = useState<{
    eventId: string
    timing?: { lockTime: string; resolveTime: string; claimsOpenAt: string; claimDeadline: string }
    markets: Array<{ kind: 'app' | 'chain'; tier: 'top10' | 'top5' | 'top1'; pool: string; state: number; stateLabel: string; noWinner: boolean; finalized: boolean; label: string }>
    totalPool: string
  } | null>(null)

  const totalPoolUsdc = useMemo(() => Number(activitySummary?.totalPool ?? '0'), [activitySummary])
  const lockTime = useMemo(() => {
    const raw = activitySummary?.timing?.lockTime
    return raw ? BigInt(raw) : null
  }, [activitySummary])

  const weekLabel = useMemo(() => {
    const raw = activitySummary?.eventId
    return raw ? `Event #${raw}` : null
  }, [activitySummary])

  const [open, setOpen] = useState(false)
  const [apps, setApps] = useState<LeaderboardEntry[]>([])
  const [appsLoading, setAppsLoading] = useState(true)
  const [lastUpdateMs, setLastUpdateMs] = useState<number | null>(null)
  const [nextRefreshMs, setNextRefreshMs] = useState<number | null>(null)
  const [selectedApp, setSelectedApp] = useState('')
  const [selectedEntry, setSelectedEntry] = useState<LeaderboardEntry | null>(null)
  const [txStep, setTxStep] = useState<'idle' | 'signing' | 'submitting' | 'confirmed' | 'error'>('idle')
  const [celebrate, setCelebrate] = useState(false)
  const [toast, setToast] = useState('')
  const [activeTab, setActiveTab] = useState<'markets' | 'track' | 'results' | 'profile'>('markets')
  const [marketType, setMarketType] = useState<'app' | 'chain'>('chain')
  const [mounted, setMounted] = useState(false)
  const [showOnboarding, setShowOnboarding] = useState<boolean | null>(null)
  const [showNotifyPrompt, setShowNotifyPrompt] = useState(false)

  const smartWallet = useMemo(
    () => connectors.find((c) => c.name.toLowerCase().includes('coinbase')),
    [connectors],
  )

  const eventTierConfig = useMemo(() => {
    try {
      return getEventTierConfig(TARGET_CHAIN)
    } catch {
      return null
    }
  }, [])

  const wrongChain = isConnected && chainId !== base.id
  const identityLabel = ensName || 'Connected User'

  useEffect(() => {
    setMounted(true)
  }, [])

  useEffect(() => {
    if (!mounted || typeof window === 'undefined') return
    const seen = window.localStorage.getItem('baserank_onboarding_seen')
    setShowOnboarding(!seen)
  }, [mounted])

  useEffect(() => {
    let cancelled = false

    async function loadApps() {
      try {
        setAppsLoading(true)
        const res = await fetch(`/api/leaderboard?market=${marketType}`, { cache: 'no-store' })
        const data = (await res.json()) as {
          entries?: LeaderboardEntry[]
          fetchedAt?: string
          nextRefreshAt?: string
          lastUpdated?: string | null
        }
        if (cancelled) return
        const list = data.entries?.slice(0, 50) ?? []
        setApps(list)
        if (list.length > 0) {
          const nextSelected = list.find((x) => x.projectName === selectedApp) ?? list[0]
          setSelectedApp(nextSelected.projectName)
          setSelectedEntry(nextSelected)
        } else {
          setSelectedEntry(null)
        }
        setLastUpdateMs(data.lastUpdated ? new Date(data.lastUpdated).getTime() : data.fetchedAt ? new Date(data.fetchedAt).getTime() : Date.now())
        setNextRefreshMs(data.nextRefreshAt ? new Date(data.nextRefreshAt).getTime() : Date.now() + 60_000)
      } finally {
        if (!cancelled) setAppsLoading(false)
      }
    }

    loadApps()
    const poll = setInterval(loadApps, 60_000)
    return () => {
      cancelled = true
      clearInterval(poll)
    }
  }, [marketType, selectedApp])

  useEffect(() => {
    let cancelled = false
    async function loadActivity() {
      try {
        const r = await fetch('/api/activity', { cache: 'no-store' })
        const d = await r.json()
        if (!cancelled) setActivitySummary(d)
      } catch {
        if (!cancelled) setActivitySummary(null)
      }
    }
    loadActivity()
    const iv = setInterval(loadActivity, 15_000)
    return () => {
      cancelled = true
      clearInterval(iv)
    }
  }, [])

  useEffect(() => {
    if (!isConfirmed) return
    setTxStep('confirmed')
    setCelebrate(true)
    setToast('Prediction Locked! 🔵')

    if (typeof window !== 'undefined' && !window.localStorage.getItem('baserank_notifications_prompted')) {
      setShowNotifyPrompt(true)
      window.localStorage.setItem('baserank_notifications_prompted', '1')
    }

    const t1 = setTimeout(() => setCelebrate(false), 2200)
    const t2 = setTimeout(() => setToast(''), 2600)
    return () => {
      clearTimeout(t1)
      clearTimeout(t2)
    }
  }, [isConfirmed])

  async function handleSubmit({ tier, amount }: { tier: number; amount: string }) {
    try {
      if (!eventTierConfig) throw new Error('Event-tier mode requires complete config; no legacy fallback allowed')
      if (!isConnected || !address) throw new Error('Connect wallet first')
      if (!selectedEntry) throw new Error('Select an app from the leaderboard first')

      const numAmount = Number(amount)
      if (!numAmount || numAmount < MIN_STAKE_USDC) throw new Error(`Minimum stake is $${MIN_STAKE_USDC}`)

      if (chainId !== TARGET_CHAIN) {
        switchChain({ chainId: TARGET_CHAIN })
        return
      }

      const tierKey = tierKeyFromSheetTier(tier)
      const marketKey: MarketKind = marketType
      const tierMarket = eventTierConfig.markets[marketKey]?.[tierKey]
      if (!tierMarket?.address) {
        throw new Error(`event-tier mode requires tierMarketAddress for ${marketKey}:${tierKey}`)
      }

      const candidateId = candidateIdForKey({ market: marketKey, candidateKey: selectedEntry.projectId })
      const value = parseUnits(amount, 6)

      const { createPublicClient, http } = await import('viem')
      const { base: baseChain } = await import('viem/chains')
      const publicClient = createPublicClient({ chain: baseChain, transport: http() })

      setTxStep('submitting')

      // Step 1: Check USDC allowance for the resolved TierMarket — approve if needed, wait for confirmation
      const allowance = await publicClient.readContract({
        address: USDC_BASE,
        abi: [{ type: 'function', name: 'allowance', stateMutability: 'view', inputs: [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }], outputs: [{ name: '', type: 'uint256' }] }],
        functionName: 'allowance',
        args: [address, tierMarket.address],
      }) as bigint

      if (allowance < value) {
        setToast('Step 1/2: Approve USDC…')
        const approveTxHash = await writeContractAsync({
          address: USDC_BASE,
          abi: [{ type: 'function', name: 'approve', inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }], outputs: [{ name: '', type: 'bool' }] }],
          functionName: 'approve',
          args: [tierMarket.address, value],
          chainId: TARGET_CHAIN,
        })
        await publicClient.waitForTransactionReceipt({ hash: approveTxHash })
        setToast('Step 2/2: Submitting prediction…')
      }

      // Step 2: Submit prediction to the resolved audited TierMarket only
      await writeContractAsync({
        address: tierMarket.address,
        abi: TierMarketABI,
        functionName: 'predict',
        args: [candidateId, value],
        chainId: TARGET_CHAIN,
      })

      setOpen(false)
    } catch (err) {
      console.error('[tx_failed]', err)
      const msg = err instanceof Error ? err.message : String(err)
      setTxStep('error')
      setToast(`Transaction failed: ${msg.slice(0, 80)}`)
      setTimeout(() => setToast(''), 4000)
    }
  }


  const showMarkets = activeTab === 'markets'

  if (!mounted || showOnboarding === null) {
    return <main className="fixed inset-0 bg-white dark:bg-zinc-950" />
  }

  if (showOnboarding) {
    return (
      <main className="fixed inset-0 z-[90] grid w-full max-w-[100vw] place-items-center overflow-hidden bg-white p-4 text-zinc-950 dark:bg-zinc-950 dark:text-white">
        <motion.div
          initial={{ opacity: 0.4, scale: 1 }}
          animate={{ opacity: [0.4, 0.7, 0.4], scale: [1, 1.1, 1] }}
          transition={{ duration: 4, repeat: Infinity, ease: 'easeInOut' }}
          className="pointer-events-none absolute -top-20 right-[-90px] h-64 w-64 rounded-full bg-[#0052FF]/45 blur-3xl"
        />

        <motion.div
          initial="hidden"
          animate="visible"
          variants={{
            hidden: { opacity: 0 },
            visible: { opacity: 1, transition: { delayChildren: 0.25, staggerChildren: 0.1 } },
          }}
          className="relative w-full max-w-sm overflow-y-hidden overflow-x-visible border border-zinc-200 p-6 dark:border-zinc-800"
        >
          <div className="overflow-hidden">
            <motion.p
              variants={{ hidden: { opacity: 0, y: 50 }, visible: { opacity: 1, y: 0 } }}
              transition={{ type: 'spring', stiffness: 400, damping: 30 }}
              className="text-sm font-semibold uppercase tracking-wider text-zinc-500"
            >
              BaseRank
            </motion.p>
          </div>
          <div className="mt-1 overflow-y-hidden overflow-x-visible">
            <motion.h2
              variants={{ hidden: { opacity: 0, y: 50 }, visible: { opacity: 1, y: 0 } }}
              transition={{ type: 'spring', stiffness: 400, damping: 30 }}
              className="text-[clamp(3.4rem,15vw,5.2rem)] font-extrabold tracking-tighter leading-[0.92]"
            >
              BaseRank
            </motion.h2>
          </div>
          <div className="mt-3 overflow-hidden">
            <motion.p
              variants={{ hidden: { opacity: 0, y: 50 }, visible: { opacity: 1, y: 0 } }}
              transition={{ type: 'spring', stiffness: 400, damping: 30 }}
              className="text-lg text-zinc-500"
            >
              Predict the weekly dApp leaderboard. Win USDC.
            </motion.p>
          </div>
          <div className="mt-4 border border-zinc-200 p-4 dark:border-zinc-800">
            <p className="mb-3 text-xs font-semibold uppercase tracking-wide text-zinc-500">How to play</p>
            <div className="space-y-3 text-sm">
              <div className="flex items-start gap-2"><span>🎯</span><p><span className="font-semibold">Predict:</span> Swipe on apps you think will top the weekly Base Builder leaderboard.</p></div>
              <div className="flex items-start gap-2"><span>🔒</span><p><span className="font-semibold">Lock:</span> Positions lock when the weekly epoch ends.</p></div>
              <div className="flex items-start gap-2"><span>💰</span><p><span className="font-semibold">Claim:</span> If your app ranks, you win a share of the USDC pool.</p></div>
            </div>
          </div>
          <div className="mt-4 overflow-hidden">
            <motion.button
              variants={{ hidden: { opacity: 0, y: 50 }, visible: { opacity: 1, y: 0 } }}
              transition={{ type: 'spring', stiffness: 400, damping: 30 }}
              className="h-14 w-full rounded-full bg-[#0052FF] text-xl font-bold text-white"
              onClick={() => {
                window.localStorage.setItem('baserank_onboarding_seen', '1')
                setShowOnboarding(false)
              }}
            >
              Start Predicting
            </motion.button>
          </div>
        </motion.div>
      </main>
    )
  }

  return (
    <main className="min-h-screen bg-white text-zinc-950 dark:bg-zinc-950 dark:text-white">

      {showNotifyPrompt && (
        <div className="fixed inset-0 z-[95] grid place-items-end bg-black/40 p-4">
          <div className="w-full max-w-md border border-zinc-200 bg-white p-5 dark:border-zinc-800 dark:bg-zinc-950">
            <div className="mx-auto mb-3 grid h-12 w-12 place-items-center rounded-full bg-zinc-100 text-xl dark:bg-zinc-900">🔔</div>
            <h3 className="text-center text-2xl font-extrabold tracking-tight">Get Notified When You Win.</h3>
            <p className="mt-2 text-center text-sm text-zinc-500">
              We&apos;ll only alert you when the weekly leaderboard resolves and your payouts are ready.
            </p>
            <div className="mt-4 grid gap-2">
              <button
                className="h-11 min-h-11 rounded-full bg-[#0052FF] text-sm font-bold text-white"
                onClick={async () => {
                  const result = await requestBaseNotificationPermission()
                  setToast(result.ok ? 'Alerts enabled' : 'Could not enable alerts on this client')
                  setTimeout(() => setToast(''), 2200)
                  setShowNotifyPrompt(false)
                }}
              >
                Enable Alerts
              </button>
              <button
                className="h-11 min-h-11 rounded-full border border-zinc-300 text-sm font-semibold dark:border-zinc-700"
                onClick={() => setShowNotifyPrompt(false)}
              >
                Not now
              </button>
            </div>
          </div>
        </div>
      )}

      {celebrate && (
        <div
          className="pointer-events-none fixed inset-0 z-[60] overflow-hidden"
          style={{ animation: 'fadeOut 2s ease-out 0.5s forwards' }}
          onAnimationEnd={() => setCelebrate(false)}
        >
          {Array.from({ length: 18 }).map((_, i) => (
            <span
              key={i}
              className="absolute h-3 w-3 rounded-full bg-[#0052FF]"
              style={{
                left: `${(i * 97) % 100}%`,
                top: `${(i * 43) % 40}%`,
                animation: `confettiFall 1.8s ease-in ${(i % 6) * 100}ms forwards`,
                opacity: 0,
              }}
            />
          ))}
          <style>{`
            @keyframes confettiFall {
              0% { opacity: 1; transform: translateY(0) scale(1); }
              100% { opacity: 0; transform: translateY(120px) scale(0.5); }
            }
            @keyframes fadeOut {
              0% { opacity: 1; }
              100% { opacity: 0; }
            }
          `}</style>
        </div>
      )}

      {toast && (
        <div className="fixed bottom-20 left-1/2 z-[70] -translate-x-1/2 rounded-full border border-zinc-300 bg-white px-4 py-2 text-sm text-zinc-900 dark:border-zinc-700 dark:bg-zinc-900 dark:text-white">
          {toast}
        </div>
      )}

      <div className="mx-auto max-w-md pb-28 pt-0">
        <header className="sticky top-0 z-40 mb-2 flex items-center justify-between border-b border-zinc-200 bg-white px-6 py-3 dark:border-zinc-800 dark:bg-zinc-950">
          <div>
            <p className="text-xs uppercase tracking-widest text-zinc-500">Base Mini App</p>
            <h1 className="flex items-center gap-2 text-xl font-semibold text-zinc-950 dark:text-white">
              BaseRank
              <span className="inline-flex items-center gap-1 text-[10px] font-mono text-[#0052FF]">
                <span className="h-2 w-2 animate-pulse rounded-full bg-[#0052FF]" /> LIVE
              </span>
            </h1>
          </div>

          {isConnected ? (
            <button onClick={() => disconnect()} className="flex h-11 min-h-11 items-center gap-2 rounded-full border border-zinc-300 px-3 text-xs dark:border-zinc-700">
              {ensAvatar ? (
                <Image src={ensAvatar} alt="avatar" width={24} height={24} className="h-6 w-6 rounded-full" unoptimized />
              ) : (
                <span className="h-6 w-6 rounded-full bg-[#0052FF]" />
              )}
              <span>{identityLabel}</span>
            </button>
          ) : (
            <button
              onClick={() => smartWallet && connect({ connector: smartWallet })}
              className="h-11 min-h-11 rounded-full bg-[#0052FF] px-4 text-xs font-bold text-white"
              disabled={!smartWallet || isPending}
            >
              {isPending ? 'Connecting...' : 'Connect'}
            </button>
          )}
        </header>

        {wrongChain && (
          <div className="mb-4 border border-amber-300 bg-amber-50 p-3 text-xs text-amber-700 dark:border-amber-900/40 dark:bg-amber-950/30 dark:text-amber-300">
            Wrong network. Switch to Base or Base Sepolia.
          </div>
        )}

        <section className="mb-4 border-b border-zinc-200 px-6 pb-4 dark:border-zinc-800">
          <p className="text-xs uppercase tracking-wide text-zinc-500">Weekly prediction volume</p>
          <p className="mt-1 text-5xl font-extrabold tracking-tighter">
            {totalPoolUsdc >= 1000 ? `$${(totalPoolUsdc / 1000).toFixed(1)}K` : totalPoolUsdc >= 1 ? `$${totalPoolUsdc.toFixed(2)}` : `$${totalPoolUsdc.toFixed(2)}`}
          </p>
          <div className="mt-2 flex items-center gap-3 text-xs">
            <span className="rounded-full bg-blue-50 px-2 py-1 font-semibold text-[#0052FF] dark:bg-blue-950/40 dark:text-blue-300">
              {totalPoolUsdc > 0 ? 'Live on Base' : 'Markets open'}
            </span>
            <span className="text-zinc-500">{weekLabel ?? 'Current event'}</span>
          </div>
        </section>

        {(isTxSending || isConfirming || txStep === 'confirmed' || txStep === 'error') && (
          <div className="mb-4 border border-zinc-200 bg-zinc-50 p-3 text-xs text-zinc-700 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-200">
            {txStep === 'signing' && 'Signing transaction...'}
            {txStep === 'submitting' && 'Submitting transaction...'}
            {isConfirming && 'Waiting for confirmation...'}
            {txStep === 'confirmed' && 'Prediction confirmed ✅'}
            {txStep === 'error' && 'Transaction failed. Please retry.'}
            {txStep === 'confirmed' && <div className="mt-2 text-[#0052FF]">You can now share your prediction from your wallet activity.</div>}
          </div>
        )}

        {showMarkets ? (
          <section className="space-y-3">
            <div className="flex items-center justify-between px-6 pb-1 text-xs">
              <span className="text-zinc-500">{formatLastUpdate(lastUpdateMs)}</span>
              <span className="rounded-full bg-zinc-100 px-3 py-1 font-bold tracking-tight text-zinc-900 dark:bg-zinc-900 dark:text-white">
                <CountdownTimer nextRefreshMs={lockTime ? Number(lockTime) * 1000 : nextRefreshMs} label={lockTime ? 'Locks in' : undefined} />
              </span>
            </div>
            <div className="px-6 pb-2">
              <div className="inline-flex rounded-full border border-zinc-200 p-1 dark:border-zinc-800">
                <button
                  onClick={() => setMarketType('chain')}
                  className={`h-11 min-h-11 rounded-full px-3 text-xs font-bold ${marketType === 'chain' ? 'bg-[#0052FF] text-white' : 'text-zinc-500'}`}
                >
                  Base Chain
                </button>
                <button
                  onClick={() => setMarketType('app')}
                  className={`h-11 min-h-11 rounded-full px-3 text-xs font-bold ${marketType === 'app' ? 'bg-[#0052FF] text-white' : 'text-zinc-500'}`}
                >
                  Base App
                </button>
              </div>
            </div>
            {appsLoading && <div className="px-6 text-sm text-zinc-500">Loading leaderboard candidates…</div>}
            {!appsLoading &&
              apps.map((entry) => {
                const wtus = Number(entry.weeklyTransactingUsers || '0')
                const canTrade = entry.tradeable !== false

                return (
                  <button
                    key={entry.projectId}
                    onClick={() => {
                      if (!canTrade) return
                      setSelectedApp(entry.projectName)
                      setSelectedEntry(entry)
                      setOpen(true)
                    }}
                    className={`w-full border-b border-zinc-200 px-6 py-3 text-left dark:border-zinc-800 ${!canTrade ? 'opacity-60' : ''}`}
                  >
                    <div className="flex items-center gap-3">
                      <div className="grid h-9 w-9 flex-shrink-0 place-items-center rounded-full bg-zinc-200 text-xs font-bold dark:bg-zinc-800">
                        {entry.rank}
                      </div>
                      {entry.iconUrl ? (
                        <Image src={entry.iconUrl} alt={entry.projectName} width={36} height={36} className="h-9 w-9 flex-shrink-0 rounded-full" unoptimized />
                      ) : (
                        <div className="h-9 w-9 flex-shrink-0 rounded-full bg-zinc-200 dark:bg-zinc-800" />
                      )}
                      <div className="min-w-0 flex-1">
                        <h3 className="truncate text-sm font-semibold leading-tight">{entry.projectName}</h3>
                        <p className="text-xs text-zinc-500">{wtus > 0 ? `${wtus.toLocaleString()} WTUs` : 'No data yet'}</p>
                      </div>
                      {canTrade ? (
                        <span className="flex-shrink-0 rounded-full bg-[#0052FF] px-3 py-1.5 text-xs font-bold text-white">Trade</span>
                      ) : (
                        <span className="flex-shrink-0 rounded-full bg-zinc-100 px-3 py-1.5 text-xs text-zinc-400 dark:bg-zinc-800">—</span>
                      )}
                    </div>
                  </button>
                )
              })}
          </section>
        ) : (
          <section className="px-6 py-6">
            {activeTab === 'track' && (
              <TrackTab
                address={address}
                isConnected={isConnected}
                onConnect={() => smartWallet && connect({ connector: smartWallet })}
                onExplore={() => setActiveTab('markets')}
              />
            )}

            {activeTab === 'results' && (
              <ResultsTab />
            )}

            {activeTab === 'profile' && (
              <div className="space-y-3 border border-zinc-200 p-4 dark:border-zinc-800">
                {!isConnected ? (
                  <div className="grid min-h-[240px] place-items-center text-center">
                    <div>
                      <div className="mx-auto mb-3 grid h-14 w-14 place-items-center rounded-full bg-zinc-100 text-xl dark:bg-zinc-900">◌</div>
                      <p className="text-xl font-bold tracking-tight">Connect to view your stats</p>
                      <p className="mt-1 text-sm text-zinc-500">Sign in with Smart Wallet to load profile and balances.</p>
                      <button
                        className="mt-4 h-11 min-h-11 rounded-full bg-[#0052FF] px-5 text-sm font-bold text-white"
                        onClick={() => smartWallet && connect({ connector: smartWallet })}
                      >
                        Connect Wallet
                      </button>
                    </div>
                  </div>
                ) : (
                  <>
                    <div className="flex items-center gap-3">
                      {ensAvatar ? (
                        <Image src={ensAvatar} alt="avatar" width={44} height={44} className="h-11 w-11 rounded-full" unoptimized />
                      ) : (
                        <span className="h-11 w-11 rounded-full bg-[#0052FF]" />
                      )}
                      <div>
                        <p className="text-base font-semibold">{identityLabel}</p>
                        <p className="text-xs text-zinc-500">Smart Wallet connected</p>
                      </div>
                    </div>
                    <div className="border-t border-zinc-200 pt-3 text-sm dark:border-zinc-800">
                      <p className="text-zinc-500">USDC balance</p>
                      <p className="text-2xl font-extrabold tracking-tight">{usdcLoading ? 'Loading…' : `${Number(usdcBalance?.formatted ?? '0').toFixed(2)} USDC`}</p>
                      {!usdcLoading && Number(usdcBalance?.formatted ?? '0') === 0 && (
                        <p className="mt-1 text-xs text-zinc-500">Fund your Smart Wallet to start predicting.</p>
                      )}
                    </div>
                  </>
                )}
              </div>
            )}
          </section>
        )}

        <footer className="mt-6 border-t border-zinc-200 p-3 text-[11px] text-zinc-500 dark:border-zinc-800 dark:text-zinc-400">
          <p>2% protocol fee. Markets resolved from official Base leaderboard snapshots.</p>
        </footer>
      </div>

      <nav className="fixed bottom-0 left-0 right-0 z-50 border-t border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-950">
        <div className="mx-auto grid h-16 max-w-md grid-cols-4">
          {[
            { key: 'markets', label: 'Markets', icon: '◫' },
            { key: 'track', label: 'Track', icon: '◎' },
            { key: 'results', label: 'Results', icon: '◉' },
            { key: 'profile', label: 'Profile', icon: '◌' },
          ].map((item) => (
            <button
              key={item.key}
              onClick={() => setActiveTab(item.key as typeof activeTab)}
              className={`min-h-11 min-w-11 px-2 text-xs ${activeTab === item.key ? 'text-[#0052FF] font-semibold' : 'text-zinc-400'}`}
            >
              <div className="relative flex flex-col items-center justify-center gap-1">
                <span className={`text-sm ${activeTab === item.key ? 'opacity-100' : 'opacity-70'}`}>{item.icon}</span>
                <span>{item.label}</span>

              </div>
            </button>
          ))}
        </div>
      </nav>

      <BetSheet
        open={open}
        onClose={() => setOpen(false)}
        onSubmit={handleSubmit}
        busy={isTxSending || isConfirming}
        app={selectedApp}
        connected={isConnected}
        poolUsdc={totalPoolUsdc}
      />
    </main>
  )
}

type Position = {
  app: string
  market: string
  amount: string
  rank: number | null
  iconUrl: string | null
  weeklyUsers: string | null
  betType?: string // V3: "top1" | "top5" | "top10"
}

function TrackTab({ address, isConnected, onConnect, onExplore }: {
  address: `0x${string}` | undefined
  isConnected: boolean
  onConnect: () => void
  onExplore: () => void
}) {
  const [positions, setPositions] = useState<Position[]>([])
  const [loaded, setLoaded] = useState(false)
  const [view, setView] = useState<'live' | 'results'>('live')
  const [totalStake, setTotalStake] = useState(0)
  const demoReceipt = {
    total: 4520,
    entries: [
      { label: 'Talent Protocol', pill: '#1 Pick · 10x', amount: 4000 },
      { label: 'Coinbase Wallet', pill: 'Top 10 · 1x', amount: 520 },
    ],
  }

  useEffect(() => {
    if (!address) return
    let cancelled = false
    async function load() {
      try {
        const r = await fetch(`/api/positions?address=${address}`, { cache: 'no-store' })
        const d = await r.json()
        if (!cancelled) {
          setPositions(d.positions ?? [])
          setTotalStake(Number(d.total ?? 0))
          setLoaded(true)
        }
      } catch {
        if (!cancelled) setLoaded(true)
      }
    }
    load()
    return () => { cancelled = true }
  }, [address])

  const betTypePill = (bt?: string) => {
    if (!bt) return null
    if (bt === 'top1') return <span className="rounded-full bg-[#0052FF] px-2 py-0.5 text-[10px] font-bold uppercase tracking-wider text-white">#1 Pick · 10x</span>
    if (bt === 'top5') return <span className="rounded-full bg-[#0052FF]/10 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wider text-[#0052FF]">Top 5 · 3x</span>
    return <span className="rounded-full bg-zinc-800 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wider text-zinc-400">Top 10 · 1x</span>
  }

  const trackFooter = (
    address && <p className="text-[10px] text-zinc-400 font-mono">Connected: {address.slice(0, 6)}...{address.slice(-4)}</p>
  )

  const liveView = (
    <>
      {!isConnected ? (
        <div className="grid min-h-[220px] place-items-center rounded-2xl border border-zinc-800 bg-zinc-900/50 p-6 text-center">
          <div>
            <div className="mx-auto mb-3 grid h-14 w-14 place-items-center rounded-full bg-zinc-800 text-xl">◌</div>
            <p className="text-xl font-bold tracking-tight">Connect to view bets</p>
            <p className="mt-1 text-sm text-zinc-500">Connect your Smart Wallet to track predictions.</p>
            <button className="mt-4 h-11 min-h-11 rounded-full bg-[#0052FF] px-5 text-sm font-bold text-white" onClick={onConnect}>
              Connect Wallet
            </button>
          </div>
        </div>
      ) : !loaded ? (
        <div className="grid min-h-[120px] place-items-center rounded-2xl border border-zinc-800 bg-zinc-900/50 p-6 text-center">
          <p className="text-sm text-zinc-500">Loading bets…</p>
        </div>
      ) : totalStake <= 0 ? (
        <div className="grid min-h-[220px] place-items-center rounded-2xl border border-zinc-800 bg-zinc-900/50 p-6 text-center">
          <div>
            <div className="mx-auto mb-3 grid h-14 w-14 place-items-center rounded-full bg-zinc-800 text-xl">◎</div>
            <p className="text-xl font-bold tracking-tight">No active picks</p>
            <p className="mt-1 text-sm text-zinc-500">Place your first prediction to track it here.</p>
            <button className="mt-4 h-11 min-h-11 rounded-full bg-[#0052FF] px-5 text-sm font-bold text-white" onClick={onExplore}>
              Explore Markets
            </button>
          </div>
        </div>
      ) : positions.length > 0 ? (
        <div className="space-y-3">
          <p className="text-xs font-semibold uppercase tracking-widest text-zinc-500">Live Bets ({positions.length})</p>
          {positions.map((p, i) => (
            <div key={i} className="flex items-center gap-3 rounded-2xl border border-zinc-800 bg-zinc-900/50 p-4">
              {p.iconUrl ? (
                <Image src={p.iconUrl} alt={p.app} width={48} height={48} className="h-12 w-12 rounded-2xl" unoptimized />
              ) : (
                <span className="grid h-12 w-12 place-items-center rounded-2xl bg-[#0052FF]/10 text-base font-bold text-[#0052FF]">
                  {p.app.charAt(0)}
                </span>
              )}
              <div className="flex-1 min-w-0">
                <p className="text-sm font-semibold truncate">{p.app}</p>
                <p className="text-[11px] text-zinc-500">
                  {p.market === 'App' ? 'App Market' : 'Chain Market'}
                  {p.rank ? ` · Rank #${p.rank}` : ''}
                </p>
                <div className="mt-1 flex items-center gap-1.5">
                  <span className="rounded-full bg-zinc-800 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wider text-zinc-400">
                    {p.market === 'App' ? 'App Market' : 'Chain Market'}
                  </span>
                  {betTypePill(p.betType)}
                </div>
              </div>
              <div className="text-right shrink-0 pl-2">
                <p className="text-lg font-bold font-mono">${Number(p.amount).toFixed(2)}</p>
                <p className="text-[10px] text-zinc-500">USDC</p>
              </div>
            </div>
          ))}
          <p className="text-[11px] text-zinc-500">Bets lock when the epoch ends. Claim winnings after resolution.</p>
        </div>
      ) : (
        <div className="space-y-3">
          <p className="text-xs font-semibold uppercase tracking-widest text-zinc-500">Live Bets</p>
          {totalStake > 0 && (
            <div className="rounded-2xl border border-zinc-800 bg-zinc-900/50 p-4 text-sm text-zinc-500">
              Bets detected on-chain, but no breakdown returned yet.
            </div>
          )}
        </div>
      )}
    </>
  )

  const heroAmount = (demoReceipt.total / 100).toFixed(2)
  const shareText = encodeURIComponent(`I just won $${heroAmount} predicting Base apps on BaseRank.`)
  const shareUrl = `https://warpcast.com/~/compose?text=${shareText}`

  const resultsView = (
    <div className="space-y-4">
      <div className="relative overflow-hidden rounded-3xl border border-white/10 bg-gradient-to-br from-[#0b1c2d] via-[#02050a] to-black p-6">
        <p className="text-[11px] uppercase tracking-[0.4em] text-white/60">You Won</p>
        <p className="mt-2 text-5xl font-extrabold tracking-tight text-[#7dffbe] font-mono">+${heroAmount}</p>
        <p className="mt-1 text-sm text-white/70">Event-tier preview payout</p>
      </div>

      <div className="rounded-3xl border border-white/10 bg-zinc-950/60 p-5 shadow-[0_25px_60px_rgba(0,0,0,0.45)]">
        <div className="flex items-center justify-between text-[11px] uppercase tracking-[0.3em] text-white/60">
          <span>Bet Receipt</span>
          <span className="rounded-full border border-white/20 px-2 py-0.5">Preview</span>
        </div>
        <div className="mt-4 space-y-3">
          {demoReceipt.entries.map((entry, idx) => (
            <div key={idx} className="flex items-center justify-between">
              <div>
                <p className="text-sm font-semibold text-white">{entry.label}</p>
                <p className="text-[11px] text-white/60">{entry.pill}</p>
              </div>
              <p className="text-lg font-semibold text-white font-mono">+${(entry.amount / 100).toFixed(2)}</p>
            </div>
          ))}
        </div>
        <div className="mt-4 flex items-center justify-between border-t border-white/10 pt-3 text-sm font-semibold text-white">
          <span>Total</span>
          <span>${heroAmount}</span>
        </div>
        <div className="mt-5 space-y-2">
          <button className="w-full rounded-full bg-[#0052FF] py-3 text-sm font-bold text-white disabled:opacity-30" disabled>
            Claim wiring lands in Unit 4
          </button>
          <a href={shareUrl} target="_blank" rel="noreferrer" className="block w-full rounded-full border border-white/30 py-3 text-center text-sm font-semibold text-white/80 hover:text-white">
            Share win
          </a>
        </div>
      </div>
    </div>
  )

  const visibleTotalStake = isConnected ? totalStake : 0

  return (
    <div className="space-y-4">
      <div className="rounded-2xl border border-zinc-800 bg-zinc-900/50 p-5">
        <p className="text-[10px] uppercase tracking-widest text-zinc-500">Your Total Stake</p>
        <p className="mt-1 text-3xl font-extrabold tracking-tight font-mono">${visibleTotalStake.toFixed(2)} <span className="text-base font-semibold text-zinc-500">USDC</span></p>
      </div>

      <div className="mx-auto flex w-full max-w-xs items-center rounded-full bg-[#0f0f0f] p-1 text-[11px] font-semibold uppercase tracking-widest shadow-[0_0_30px_rgba(0,0,0,0.35)]">
        {(['live', 'results'] as const).map((key) => {
          const active = view === key
          return (
            <button
              key={key}
              onClick={() => setView(key)}
              className={`${active ? 'bg-white text-black shadow-[0_5px_20px_rgba(255,255,255,0.25)]' : 'text-zinc-500'} flex-1 rounded-full px-4 py-1 text-center transition`}
            >
              {key === 'live' ? 'Live' : 'Results'}
            </button>
          )
        })}
      </div>

      {view === 'live' ? liveView : resultsView}

      {trackFooter}
    </div>
  )
}

type PoolSummary = {
  eventId?: string
  markets: Array<{ kind: 'app' | 'chain'; tier: 'top10' | 'top5' | 'top1'; pool: string; state: number; stateLabel: string; label: string }>
  totalPool: string
}

function ResultsTab() {
  const [pools, setPools] = useState<PoolSummary | null>(null)
  const [loaded, setLoaded] = useState(false)

  useEffect(() => {
    let cancelled = false
    async function load() {
      try {
        const r = await fetch('/api/activity', { cache: 'no-store' })
        const d = await r.json()
        if (!cancelled) { setPools(d); setLoaded(true) }
      } catch {
        if (!cancelled) setLoaded(true)
      }
    }
    load()
    const iv = setInterval(load, 15_000)
    return () => { cancelled = true; clearInterval(iv) }
  }, [])

  return (
    <div className="space-y-4">
      <div className="border border-zinc-200 p-4 dark:border-zinc-800">
        <p className="text-xs uppercase tracking-wide text-zinc-500">Market Pools</p>
        {!loaded ? (
          <p className="mt-3 text-sm text-zinc-400">Loading...</p>
        ) : !pools ? (
          <p className="mt-3 text-sm text-zinc-500">Unable to load market data.</p>
        ) : (
          <div className="mt-3 space-y-3">
            {pools.markets.map((market) => (
              <div key={`${market.kind}-${market.tier}`} className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                  <span className="grid h-8 w-8 place-items-center rounded-full bg-[#0052FF]/10 text-xs font-bold text-[#0052FF]">{market.kind === 'app' ? 'A' : 'C'}</span>
                  <div>
                    <p className="text-sm font-semibold">{market.label}</p>
                    <p className="text-xs text-zinc-500">{market.stateLabel}</p>
                  </div>
                </div>
                <span className="text-lg font-bold">${Number(market.pool).toFixed(2)}</span>
              </div>
            ))}
            <div className="border-t border-zinc-200 pt-2 dark:border-zinc-700">
              <div className="flex items-center justify-between">
                <span className="text-sm font-medium text-zinc-500">Total Pool</span>
                <span className="text-lg font-extrabold">${pools.totalPool}</span>
              </div>
            </div>
          </div>
        )}
      </div>

      <div className="border border-zinc-200 p-4 dark:border-zinc-800">
        <p className="text-xs uppercase tracking-wide text-zinc-500">How It Works</p>
        <div className="mt-3 space-y-3 text-sm text-zinc-600 dark:text-zinc-400">
          <div className="flex items-start gap-2">
            <span className="mt-0.5 grid h-5 w-5 shrink-0 place-items-center rounded-full bg-[#0052FF] text-[10px] font-bold text-white">1</span>
            <p>Markets open weekly. Predict which apps will top the Base leaderboard.</p>
          </div>
          <div className="flex items-start gap-2">
            <span className="mt-0.5 grid h-5 w-5 shrink-0 place-items-center rounded-full bg-[#0052FF] text-[10px] font-bold text-white">2</span>
            <p>Positions lock when the epoch ends. No new predictions after lock.</p>
          </div>
          <div className="flex items-start gap-2">
            <span className="mt-0.5 grid h-5 w-5 shrink-0 place-items-center rounded-full bg-[#0052FF] text-[10px] font-bold text-white">3</span>
            <p>Winners are resolved from the official Base leaderboard snapshot. Payouts distribute automatically.</p>
          </div>
        </div>
      </div>

      <div className="border border-zinc-200 p-4 dark:border-zinc-800">
        <p className="text-xs uppercase tracking-wide text-zinc-500">Past Results</p>
        <div className="mt-3 grid min-h-[80px] place-items-center text-center">
          <div>
            <p className="text-lg font-bold tracking-tight">No results yet</p>
            <p className="mt-1 text-sm text-zinc-500">Winners and payouts appear here after each epoch resolves.</p>
          </div>
        </div>
      </div>

      <div className="border border-zinc-200 p-4 text-xs text-zinc-500 dark:border-zinc-800">
        <p className="font-semibold text-zinc-700 dark:text-zinc-300">Transparency</p>
        <p className="mt-1">Markets are resolved using official Base leaderboard snapshots. Each resolution includes an on-chain snapshot hash for verification.</p>
        <p className="mt-2">2% protocol fee · Event-tier markets are isolated per leaderboard type and tier.</p>
      </div>
    </div>
  )
}
