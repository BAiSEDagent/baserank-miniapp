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

  useReadContract,
} from 'wagmi'
import { parseUnits, encodePacked, keccak256, getAddress } from 'viem'
import { base } from 'wagmi/chains'
import { BetSheet } from '@/components/bet-sheet'
import { CountdownTimer } from '@/components/countdown-timer'
import Image from 'next/image'
import { requestBaseNotificationPermission } from '@/lib/notifications'
import { motion } from 'framer-motion'
import { BaseRankMarketV2ABI } from '@/lib/contracts/BaseRankMarketV2ABI'

const _raw = (process.env.NEXT_PUBLIC_MARKET_ADDRESS ?? '').replace(/^["'\s]+|["'\s]+$/g, '')
const MARKET_ADDRESS: `0x${string}` | undefined = _raw
  ? (() => { try { return getAddress(_raw) } catch { return undefined } })()
  : undefined
const WEEK_ID = BigInt(20260311)
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

  // Live market stats from contract
  const { data: appMarket } = useReadContract({
    address: MARKET_ADDRESS,
    abi: BaseRankMarketV2ABI,
    functionName: 'marketDetails',
    args: [WEEK_ID, 0],
    chainId: base.id,
    query: { enabled: !!MARKET_ADDRESS, refetchInterval: 30000 },
  })
  const { data: chainMarket } = useReadContract({
    address: MARKET_ADDRESS,
    abi: BaseRankMarketV2ABI,
    functionName: 'marketDetails',
    args: [WEEK_ID, 1],
    chainId: base.id,
    query: { enabled: !!MARKET_ADDRESS, refetchInterval: 30000 },
  })
  const totalPoolUsdc = useMemo(() => {
    const a = (appMarket as { totalPool?: bigint } | undefined)?.totalPool ?? BigInt(0)
    const b = (chainMarket as { totalPool?: bigint } | undefined)?.totalPool ?? BigInt(0)
    return Number(a + b) / 1e6
  }, [appMarket, chainMarket])
  const lockTime = useMemo(() => {
    return (appMarket as { lockTime?: bigint } | undefined)?.lockTime ?? null
  }, [appMarket])

  const weekLabel = useMemo(() => {
    const oT = (appMarket as { openTime?: bigint } | undefined)?.openTime
    const lT = (appMarket as { lockTime?: bigint } | undefined)?.lockTime
    if (!oT || !lT) return null
    const fmt = (ts: bigint) => {
      const d = new Date(Number(ts) * 1000)
      return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' })
    }
    return `Week of ${fmt(oT)} – ${fmt(lT)}`
  }, [appMarket])

  const [open, setOpen] = useState(false)
  const [apps, setApps] = useState<LeaderboardEntry[]>([])
  const [appsLoading, setAppsLoading] = useState(true)
  const [lastUpdateMs, setLastUpdateMs] = useState<number | null>(null)
  const [nextRefreshMs, setNextRefreshMs] = useState<number | null>(null)
  const [selectedApp, setSelectedApp] = useState('')
  const [txStep, setTxStep] = useState<'idle' | 'signing' | 'submitting' | 'confirmed' | 'error'>('idle')
  const [celebrate, setCelebrate] = useState(false)
  const [toast, setToast] = useState('')
  const [activeTab, setActiveTab] = useState<'markets' | 'positions' | 'results' | 'profile'>('markets')
  const [marketType, setMarketType] = useState<'app' | 'chain'>('chain')
  const [mounted, setMounted] = useState(false)
  const [showOnboarding, setShowOnboarding] = useState<boolean | null>(null)
  const [showNotifyPrompt, setShowNotifyPrompt] = useState(false)

  const smartWallet = useMemo(
    () => connectors.find((c) => c.name.toLowerCase().includes('coinbase')),
    [connectors],
  )

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
        if (list.length > 0) setSelectedApp((prev) => (list.some((x) => x.projectName === prev) ? prev : list[0].projectName))
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
  }, [marketType])

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
      if (!MARKET_ADDRESS) throw new Error('Missing contract address')
      if (!isConnected || !address) throw new Error('Connect wallet first')
      if (!selectedApp) throw new Error('Select an app from the leaderboard first')

      const numAmount = Number(amount)
      if (!numAmount || numAmount < MIN_STAKE_USDC) throw new Error(`Minimum stake is $${MIN_STAKE_USDC}`)

      if (chainId !== TARGET_CHAIN) {
        switchChain({ chainId: TARGET_CHAIN })
        return
      }

      setTxStep('signing')
      const appId = keccak256(encodePacked(['string'], [`${marketType}:${selectedApp}`]))
      const value = parseUnits(amount, 6)
      const marketTypeInt = marketType === 'app' ? 0 : 1

      const { createPublicClient, http } = await import('viem')
      const { base: baseChain } = await import('viem/chains')
      const publicClient = createPublicClient({ chain: baseChain, transport: http() })

      setTxStep('submitting')

      // Step 1: Check USDC allowance — approve if needed, wait for confirmation
      const allowance = await publicClient.readContract({
        address: USDC_BASE,
        abi: [{ type: 'function', name: 'allowance', stateMutability: 'view', inputs: [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }], outputs: [{ name: '', type: 'uint256' }] }],
        functionName: 'allowance',
        args: [address, MARKET_ADDRESS],
      }) as bigint

      if (allowance < value) {
        setToast('Step 1/2: Approve USDC…')
        const approveTxHash = await writeContractAsync({
          address: USDC_BASE,
          abi: [{ type: 'function', name: 'approve', inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }], outputs: [{ name: '', type: 'bool' }] }],
          functionName: 'approve',
          args: [MARKET_ADDRESS, value],
          chainId: TARGET_CHAIN,
        })
        // Wait for approval to be mined before proceeding
        await publicClient.waitForTransactionReceipt({ hash: approveTxHash })
        setToast('Step 2/2: Submitting prediction…')
      }

      // Step 2: Submit prediction
      await writeContractAsync({
        address: MARKET_ADDRESS,
        abi: BaseRankMarketV2ABI,
        functionName: 'predict',
        args: [WEEK_ID, marketTypeInt, appId, value],
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
            {totalPoolUsdc >= 1000 ? `$${(totalPoolUsdc / 1000).toFixed(1)}K` : `$${totalPoolUsdc.toFixed(0)}`}
          </p>
          <div className="mt-2 flex items-center gap-3 text-xs">
            <span className="rounded-full bg-blue-50 px-2 py-1 font-semibold text-[#0052FF] dark:bg-blue-950/40 dark:text-blue-300">
              {totalPoolUsdc > 0 ? 'Live on Base' : 'Markets open'}
            </span>
            <span className="text-zinc-500">{weekLabel ?? `Epoch #${WEEK_ID.toString()}`}</span>
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
            {activeTab === 'positions' && (
              <div className="space-y-3">
                <div className="flex items-center justify-between border border-zinc-200 p-4 dark:border-zinc-800">
                  <div>
                    <p className="text-xs uppercase tracking-wide text-zinc-500">Unclaimed winnings</p>
                    <p className="text-2xl font-extrabold tracking-tight">$0.00 USDC</p>
                  </div>
                  <button
                    className="h-11 min-h-11 rounded-full bg-zinc-200 px-5 text-sm font-bold text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400"
                    disabled
                  >
                    Claim
                  </button>
                </div>

                <div className="grid min-h-[220px] place-items-center border border-zinc-200 p-6 text-center dark:border-zinc-800">
                  {!isConnected ? (
                    <div>
                      <div className="mx-auto mb-3 grid h-14 w-14 place-items-center rounded-full bg-zinc-100 text-xl dark:bg-zinc-900">◌</div>
                      <p className="text-xl font-bold tracking-tight">Connect to view positions</p>
                      <p className="mt-1 text-sm text-zinc-500">Connect your Smart Wallet to track your predictions.</p>
                      <button
                        className="mt-4 h-11 min-h-11 rounded-full bg-[#0052FF] px-5 text-sm font-bold text-white"
                        onClick={() => smartWallet && connect({ connector: smartWallet })}
                      >
                        Connect Wallet
                      </button>
                    </div>
                  ) : (
                    <div>
                      <div className="mx-auto mb-3 grid h-14 w-14 place-items-center rounded-full bg-zinc-100 text-xl dark:bg-zinc-900">◎</div>
                      <p className="text-xl font-bold tracking-tight">No active predictions</p>
                      <p className="mt-1 text-sm text-zinc-500">Place your first prediction to track it here.</p>
                      <button
                        className="mt-4 h-11 min-h-11 rounded-full bg-[#0052FF] px-5 text-sm font-bold text-white"
                        onClick={() => setActiveTab('markets')}
                      >
                        Explore Markets
                      </button>
                    </div>
                  )}
                </div>
              </div>
            )}

            {activeTab === 'results' && (
              <ResultsTab marketAddress={MARKET_ADDRESS} />
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
            { key: 'positions', label: 'Positions', icon: '◎' },
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

type ActivityItem = { user: string; amount: string; marketType: string; txHash: string }

function ResultsTab({ marketAddress }: { marketAddress: `0x${string}` | undefined }) {
  const [activity, setActivity] = useState<ActivityItem[]>([])
  const [loaded, setLoaded] = useState(false)

  useEffect(() => {
    fetch('/api/activity')
      .then((r) => r.json())
      .then((d) => { setActivity(d.activity ?? []); setLoaded(true) })
      .catch(() => setLoaded(true))
    const iv = setInterval(() => {
      fetch('/api/activity').then((r) => r.json()).then((d) => setActivity(d.activity ?? [])).catch(() => {})
    }, 15_000)
    return () => clearInterval(iv)
  }, [])

  return (
    <div className="space-y-4">
      <div className="border border-zinc-200 p-4 dark:border-zinc-800">
        <p className="text-xs uppercase tracking-wide text-zinc-500">Live Activity</p>
        {!loaded ? (
          <p className="mt-3 text-sm text-zinc-400">Loading...</p>
        ) : activity.length === 0 ? (
          <div className="mt-3 grid min-h-[80px] place-items-center text-center">
            <p className="text-sm text-zinc-500">No predictions yet this epoch. Be the first.</p>
          </div>
        ) : (
          <div className="mt-3 space-y-2">
            {activity.map((a, i) => (
              <div key={`${a.txHash}-${i}`} className="flex items-center justify-between text-sm">
                <div className="flex items-center gap-2">
                  <span className="h-6 w-6 rounded-full bg-[#0052FF]/10 grid place-items-center text-[10px] font-bold text-[#0052FF]">
                    {a.marketType === 'App' ? 'A' : 'C'}
                  </span>
                  <span className="font-mono text-xs text-zinc-600 dark:text-zinc-400">{a.user}</span>
                </div>
                <span className="font-semibold">${Number(a.amount).toFixed(2)}</span>
              </div>
            ))}
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
        <p className="mt-2">2% protocol fee · Contract on <a href={`https://basescan.org/address/${marketAddress}`} target="_blank" rel="noopener noreferrer" className="text-[#0052FF] underline">Basescan</a></p>
      </div>
    </div>
  )
}
