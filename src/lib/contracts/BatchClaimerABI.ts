export const BatchClaimerABI = [
  {
    type: 'function',
    name: 'claimMany',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'markets', type: 'address[]' }],
    outputs: [],
  },
  {
    type: 'function',
    name: 'previewMany',
    stateMutability: 'view',
    inputs: [
      { name: 'markets', type: 'address[]' },
      { name: 'user', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256[]' }],
  },
] as const
