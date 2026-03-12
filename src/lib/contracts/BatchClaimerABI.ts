export const BatchClaimerABI = [
  {
    type: 'event',
    name: 'ClaimSucceeded',
    inputs: [
      { name: 'user', type: 'address', indexed: true },
      { name: 'market', type: 'address', indexed: true },
    ],
    anonymous: false,
  },
  {
    type: 'event',
    name: 'ClaimFailed',
    inputs: [
      { name: 'user', type: 'address', indexed: true },
      { name: 'market', type: 'address', indexed: true },
      { name: 'reason', type: 'bytes', indexed: false },
    ],
    anonymous: false,
  },
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
