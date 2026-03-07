'use client'

import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { WagmiProvider } from 'wagmi'
import { wagmiConfig } from '@/lib/web3'
import { useEffect, useRef, useState } from 'react'
import { sdk } from '@farcaster/miniapp-sdk'
import { useConnect } from 'wagmi'

function AutoConnect() {
  const { connect, connectors } = useConnect()
  const attempted = useRef(false)
  useEffect(() => {
    if (attempted.current) return
    const frameConnector = connectors.find((c) => c.id === 'farcasterFrame')
    // Only auto-connect if we're in a Farcaster frame context
    if (frameConnector && typeof window !== 'undefined' && window.self !== window.top) {
      attempted.current = true
      connect({ connector: frameConnector })
    }
  }, [connect, connectors])
  return null
}

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(() => new QueryClient())

  useEffect(() => {
    sdk.actions.ready().catch(() => {
      // no-op outside mini app environments
    })
  }, [])

  return (
    <WagmiProvider config={wagmiConfig} reconnectOnMount>
      <QueryClientProvider client={queryClient}>
        <AutoConnect />
        {children}
      </QueryClientProvider>
    </WagmiProvider>
  )
}
