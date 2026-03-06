import type { Metadata } from 'next'
import { Inter, Geist_Mono } from 'next/font/google'
import './globals.css'
import { Providers } from '@/components/providers'

const inter = Inter({
  variable: '--font-inter',
  subsets: ['latin'],
})

const geistMono = Geist_Mono({
  variable: '--font-geist-mono',
  subsets: ['latin'],
})

export const metadata: Metadata = {
  title: 'BaseRank',
  description: 'Predict weekly Base app leaderboard outcomes',
  other: {
    'base:app_id': '69a7f79ebbe150740b4dcf90',
    'fc:miniapp': JSON.stringify({
      version: '1',
      imageUrl: 'https://baserank-miniapp.vercel.app/assets/cover-1200x630.png',
      button: {
        title: 'Predict',
        action: {
          type: 'launch_frame',
          name: 'BaseRank',
          url: 'https://baserank-miniapp.vercel.app',
        },
      },
    }),
  },
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode
}>) {
  return (
    <html lang="en">
      <body className={`${inter.variable} ${geistMono.variable} antialiased`}>
        <Providers>{children}</Providers>
      </body>
    </html>
  )
}
