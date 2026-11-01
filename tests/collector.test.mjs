import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { collect, costForCall, isPeakTime, parseUsage, priceFor, usageKey } from '../collector.mjs'

const config = JSON.parse(readFileSync(new URL('../config.json', import.meta.url), 'utf8'))

// 2026-11-02 是周一；北京时间用 UTC+8 表示
const beijing = (iso) => Date.parse(iso)

test('peak hours: weekday 09:00-12:00 / 14:00-18:00 Beijing time', () => {
  assert.equal(isPeakTime(beijing('2026-11-02T10:00:00+08:00')), true)
  assert.equal(isPeakTime(beijing('2026-11-02T15:00:00+08:00')), true)
  assert.equal(isPeakTime(beijing('2026-11-02T12:30:00+08:00')), false) // 午休
  assert.equal(isPeakTime(beijing('2026-11-02T08:59:00+08:00')), false)
  assert.equal(isPeakTime(beijing('2026-11-02T18:00:00+08:00')), false)
  assert.equal(isPeakTime(beijing('2026-11-07T10:00:00+08:00')), false) // 周六
})

test('deepseek-flash prices: peak 2 / 8 / 0.04, idle 1 / 4 / 0.02', () => {
  const oneM = { input: 1_000_000, cacheRead: 1_000_000, output: 1_000_000, model: 'deepseek-flash' }
  const peak = costForCall(oneM, beijing('2026-11-02T10:00:00+08:00'), config)
  const idle = costForCall(oneM, beijing('2026-11-02T22:00:00+08:00'), config)
  assert.equal(Number(peak.toFixed(6)), 10.04)
  assert.equal(Number(idle.toFixed(6)), 5.02)
})

test('deepseek-v4-pro prices: peak 9 / 27 / 0.30, idle 4.5 / 13.5 / 0.15', () => {
  const oneM = { input: 1_000_000, cacheRead: 1_000_000, output: 1_000_000, model: 'deepseek-v4-pro' }
  const peak = costForCall(oneM, beijing('2026-11-02T10:00:00+08:00'), config)
  assert.equal(Number(peak.toFixed(6)), 36.3)
  assert.deepEqual(priceFor('deepseek-v4-pro', beijing('2026-11-02T22:00:00+08:00'), config), { hit: 0.15, miss: 4.5, out: 13.5 })
})

test('locally deployed model is free (0 price), not unpriced', () => {
  assert.deepEqual(priceFor('GLM-5.3-Flash', Date.now(), config), { hit: 0, miss: 0, out: 0 })
  const cost = costForCall({ input: 10_000_000, cacheRead: 10_000_000, output: 1_000_000, model: 'GLM-5.3-Flash' }, Date.now(), config)
  assert.equal(cost, 0)
  // 免费模型不能落到 priceFor 的 null 分支，否则界面会报「未配置单价」
  assert.notEqual(priceFor('GLM-5.3-Flash', Date.now(), config), null)
})

test('unknown model is not priced silently', () => {
  const cost = costForCall({ input: 1_000_000, cacheRead: 0, output: 0, model: 'some-unknown-model' }, Date.now(), config)
  assert.equal(cost, 0)
  assert.equal(priceFor('some-unknown-model', Date.now(), config), null)
})

test('parseUsage pairs each call with the model in effect', () => {
  const text = [
    JSON.stringify({ type: 'request/header', time: 1, data: { header: { config: { model: 'deepseek-flash' } } } }),
    JSON.stringify({ type: 'assistant/message', time: 2, data: { usage: { inputTokens: 20, cacheReadTokens: 10, outputTokens: 5 } } }),
    JSON.stringify({ type: 'request/context', time: 3, data: { model: 'deepseek-v4-pro' } }),
    JSON.stringify({ type: 'assistant/message', time: 4, data: { usage: { inputTokens: 1, cacheReadTokens: 0, outputTokens: 2 } } }),
  ].join('\n')

  assert.deepEqual(parseUsage(text), [
    { model: 'deepseek-flash', time: 2, input: 20, output: 5, cacheRead: 10 },
    { model: 'deepseek-v4-pro', time: 4, input: 1, output: 2, cacheRead: 0 },
  ])
})

test('seeded/branched sessions are de-duplicated by call fingerprint', async () => {
  const root = mkdtempSync(join(tmpdir(), 'dss-'))
  const events = [
    JSON.stringify({ type: 'session', version: 4, cwd: '/tmp/x' }),
    JSON.stringify({ type: 'request/header', time: 1000, data: { header: { config: { model: 'deepseek-flash' } } } }),
    JSON.stringify({ type: 'assistant/message', seq: 1, time: 2000, data: { usage: { inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0 } } }),
    JSON.stringify({ type: 'assistant/message', seq: 2, time: 3000, data: { usage: { inputTokens: 500_000, outputTokens: 0, cacheReadTokens: 0 } } }),
  ].join('\n')

  // 两个会话共享前两条调用（分支会话复制历史），第三条各自独立
  for (const [id, extra] of [['session-a', true], ['session-b', false]]) {
    const dir = join(root, 'sessions', 'proj', id)
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, 'session.jsonl'), events + (extra ? '\n' + JSON.stringify({ type: 'assistant/message', seq: 3, time: 4000, data: { usage: { inputTokens: 2_000_000, outputTokens: 0, cacheReadTokens: 0 } } }) : ''))
  }

  const snap = await collect({ dshDataDir: root, prices: config.prices, defaultModel: 'deepseek-flash' })
  // 峰值/空闲均按 deepseek-flash 计：只应计 1M + 0.5M + 2M 各一次，而不是两份 1.5M
  const unit = priceFor('deepseek-flash', 2000, config)
  const expected = (1_000_000 * unit.miss + 500_000 * unit.miss + 2_000_000 * unit.miss) / 1e6
  assert.ok(Math.abs(snap.overall.total - expected) < 1e-9, `${snap.overall.total} != ${expected}`)
})

test('usageKey ignores nothing that differs', () => {
  const a = { model: 'deepseek-flash', time: 1, input: 10, output: 5, cacheRead: 0 }
  assert.equal(usageKey(a), usageKey({ ...a }))
  assert.notEqual(usageKey(a), usageKey({ ...a, output: 6 }))
  assert.notEqual(usageKey(a), usageKey({ ...a, time: 2 }))
})
