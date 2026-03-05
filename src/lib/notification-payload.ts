type BuildNotificationArgs = {
  title: string
  body: string
  targetUrl: string
  appOrigin: string
}

export function buildNotificationPayload({ title, body, targetUrl, appOrigin }: BuildNotificationArgs) {
  if (title.length > 32) throw new Error('Notification title exceeds 32 chars')
  if (body.length > 128) throw new Error('Notification body exceeds 128 chars')

  const target = new URL(targetUrl)
  const origin = new URL(appOrigin)
  if (target.origin !== origin.origin) throw new Error('targetURL must be same-domain as mini app')

  return {
    title,
    body,
    targetUrl: target.toString(),
  }
}

export function weeklyResolutionTemplate(targetUrl: string, appOrigin: string) {
  return buildNotificationPayload({
    title: 'Leaderboard resolved',
    body: '${username}, weekly results are in. Tap to see if your predictions won USDC.',
    targetUrl,
    appOrigin,
  })
}
