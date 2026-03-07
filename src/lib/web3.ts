import { http, createConfig } from 'wagmi'
import { base, baseSepolia } from 'wagmi/chains'
import { coinbaseWallet } from 'wagmi/connectors'
import { farcasterFrame } from '@farcaster/miniapp-wagmi-connector'

export const wagmiConfig = createConfig({
  chains: [baseSepolia, base],
  connectors: [
    farcasterFrame(),
    coinbaseWallet({
      appName: 'BaseRank',
      preference: 'smartWalletOnly',
    }),
  ],
  transports: {
    [base.id]: http(),
    [baseSepolia.id]: http(),
  },
})
