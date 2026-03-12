'use client'

import { AnimatePresence, animate, motion, useMotionValue } from 'framer-motion'
import { useEffect, useRef, useState } from 'react'

const tiers = [
  { id: 1, label: 'Top 10' },
  { id: 2, label: 'Top 5' },
  { id: 3, label: '#1' },
]

const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '.', '0', '⌫']

export function BetSheet(props: {
  open: boolean
  onClose: () => void
  onSubmit: (args: { tier: number; amount: string }) => Promise<void>
  busy?: boolean
  app: string
  connected: boolean
  poolUsdc?: number
}) {
  const { open } = props

  return (
    <AnimatePresence>
      {open && <OpenBetSheet key="bet-sheet-open" {...props} />}
    </AnimatePresence>
  )
}

function OpenBetSheet({
  onClose,
  onSubmit,
  busy,
  app,
  connected,
  poolUsdc,
}: {
  open: boolean
  onClose: () => void
  onSubmit: (args: { tier: number; amount: string }) => Promise<void>
  busy?: boolean
  app: string
  connected: boolean
  poolUsdc?: number
}) {
  const [tier, setTier] = useState<number>(1)
  const [amount, setAmount] = useState('0')
  const [swipeBusy, setSwipeBusy] = useState(false)

  const trackRef = useRef<HTMLDivElement>(null)
  const x = useMotionValue(0)
  const maxSwipe = 220

  useEffect(() => {
    x.set(0)
  }, [x])

  const pool = poolUsdc ?? 0

  function pushKey(k: string) {
    if (k === '⌫') {
      setAmount((prev) => (prev.length <= 1 ? '0' : prev.slice(0, -1)))
      return
    }
    if (k === '.') {
      setAmount((prev) => (prev.includes('.') ? prev : `${prev}.`))
      return
    }
    setAmount((prev) => (prev === '0' ? k : `${prev}${k}`))
  }

  const numAmount = Number(amount || '0')
  const canSubmit = connected && numAmount >= 0.01

  async function onDragEnd() {
    if (swipeBusy || busy || !canSubmit) return
    const passed = x.get() > maxSwipe * 0.8
    if (!passed) {
      animate(x, 0, { type: 'spring', stiffness: 300, damping: 25 })
      return
    }

    setSwipeBusy(true)
    animate(x, maxSwipe, { duration: 0.15 })
    await onSubmit({ tier, amount })
    setSwipeBusy(false)
    animate(x, 0, { duration: 0.15 })
  }

  return (
    <>
      <motion.div className="fixed inset-0 bg-black/50" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} onClick={onClose} />

      <motion.div
        drag="y"
        dragConstraints={{ top: 0, bottom: 0 }}
        dragElastic={{ top: 0, bottom: 0.6 }}
        onDragEnd={(_e, info) => {
          if (info.offset.y > 120 || info.velocity.y > 400) onClose()
        }}
        initial={{ y: '100%' }}
        animate={{ y: 0 }}
        exit={{ y: '100%' }}
        transition={{ type: 'spring', stiffness: 300, damping: 25 }}
        className="fixed bottom-0 left-0 right-0 z-50 mx-auto flex h-[88vh] w-full max-w-md flex-col rounded-t-3xl bg-white px-6 pt-4 text-zinc-950 dark:bg-zinc-950 dark:text-white"
      >
        <div className="mx-auto h-1.5 w-12 cursor-grab rounded-full bg-zinc-300 active:cursor-grabbing dark:bg-zinc-700" />

        <div className="mt-3 flex items-center justify-center gap-2">
          <span className="h-6 w-6 rounded-full bg-[#0052FF]" />
          <p className="text-sm font-medium text-zinc-500 dark:text-zinc-400">
            {app} • {tiers.find((t) => t.id === tier)?.label}
          </p>
        </div>

        <div className="my-6 text-center">
          <p className="text-7xl font-extrabold tracking-tighter">${amount}</p>
        </div>

        <div className="mb-4 flex justify-center">
          <span className="rounded-full bg-blue-50 px-3 py-1 text-xs font-semibold text-blue-600 dark:bg-blue-900/30 dark:text-blue-300">
            Pool: ${pool.toLocaleString()} USDC
          </span>
        </div>

        <div className="mb-4 grid grid-cols-3 gap-2">
          {tiers.map((item) => (
            <button
              key={item.id}
              onClick={() => setTier(item.id)}
              className={`h-11 min-h-11 rounded-xl text-sm ${
                tier === item.id ? 'bg-blue-50 text-[#0052FF] dark:bg-blue-950/30' : 'text-zinc-500 dark:text-zinc-400'
              }`}
            >
              {item.label}
            </button>
          ))}
        </div>

        <div className="mb-6 grid w-full grid-cols-3 gap-2 px-6">
          {keys.map((k) => (
            <button
              key={k}
              onClick={() => pushKey(k)}
              className="h-14 min-h-11 min-w-11 bg-transparent text-2xl font-semibold"
            >
              {k}
            </button>
          ))}
        </div>

        <div className="mt-auto px-4 pb-8">
          {swipeBusy || busy ? (
            <div className="flex h-14 items-center justify-center rounded-full bg-[#0052FF] font-semibold text-white">
              <span className="mr-2 h-4 w-4 animate-spin rounded-full border-2 border-white/30 border-t-white" />
              Confirming with Smart Wallet...
            </div>
          ) : (
            <div ref={trackRef} className={`relative h-14 w-full rounded-full p-1 ${canSubmit ? 'bg-[#0052FF]' : 'bg-zinc-600'}`}>
              <div className={`pointer-events-none absolute inset-0 grid place-items-center text-sm font-medium ${canSubmit ? 'text-white/90' : 'text-zinc-400'}`}>
                {!connected ? 'Connect to Predict' : !canSubmit ? 'Enter amount (min $0.01)' : 'Swipe to Predict →'}
              </div>
              {canSubmit && (
                <motion.button
                  drag="x"
                  dragConstraints={{ left: 0, right: maxSwipe }}
                  dragElastic={0.05}
                  style={{ x }}
                  onDragEnd={onDragEnd}
                  className="relative grid h-12 w-12 place-items-center rounded-full bg-white text-[#0052FF] shadow-md"
                >
                  <span className="text-lg font-bold leading-none">»</span>
                </motion.button>
              )}
            </div>
          )}
        </div>
      </motion.div>
    </>
  )
}
