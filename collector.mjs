#!/usr/bin/env node
/**
 * DeepSeekSpend Lite — 极简采集器
 * ------------------------------
 * 只回答两件事：我花了多少钱、还剩多少钱。
 *
 * 数据来源：
 *  1. {dshDataDir}/sessions/<project>/<session>/session.v4.jsonl.zstd
 *     （zstd 多帧追加日志；同时兼容 session.jsonl.zstd / session.jsonl）
 *  2. GET https://api.deepseek.com/user/balance —— 账户余额（需 API Key）
 *
 * 计价：DeepSeek 官方价目，区分高峰 / 空闲时段
 *   高峰 = 北京时间周一至周五 09:00-12:00、14:00-18:00；其余为空闲（半价）。
 *   费率见 config.json 的 prices.peakIdle。
 *
 * 用法：node collector.mjs --config <config.json> [--once]
 */

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { zstdDecompressSync } from 'node:zlib'

const LOG_NAMES = ['session.v4.jsonl.zstd', 'session.jsonl.zstd', 'session.jsonl']
const DEFAULT_CONFIG_PATH = path.join(
  os.homedir(), 'Library', 'Application Support', 'DeepSeekSpend', 'config.json',
)

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

function expandHome(p) {
  if (typeof p !== 'string') return p
  return p.startsWith('~/') ? path.join(os.homedir(), p.slice(2)) : p
}

function localHourStart(ts) {
  const d = new Date(ts)
  d.setMinutes(0, 0, 0)
  return d.getTime()
}

function localDayStart(ts) {
  const d = new Date(ts)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

function num(v) {
  return typeof v === 'number' && Number.isFinite(v) && v > 0 ? v : 0
}

/** 读取 YAML 里的 DEEPSEEK_API_KEY（可带引号） */
function readApiKey(filePath) {
  try {
    const text = fs.readFileSync(filePath, 'utf8')
    const m = text.match(/^\s*DEEPSEEK_API_KEY\s*:\s*(\S+)\s*$/m)
    return m ? m[1].replace(/^["']|["']$/g, '') : null
  } catch {
    return null
  }
}

// ---------------------------------------------------------------------------
// 日志解码（zstd 多帧 → 行）
// ---------------------------------------------------------------------------

function scanFrames(buf) {
  const starts = []
  for (let i = 0; i + 4 <= buf.length; i++) {
    if (buf[i] === 0x28 && buf[i + 1] === 0xb5 && buf[i + 2] === 0x2f && buf[i + 3] === 0xfd) {
      starts.push(i)
      i += 3
    }
  }
  return starts
}

/** 解压整个日志；写入中的最后一个不完整帧直接从尾部丢弃 */
export function decodeLogFile(filePath) {
  const buf = fs.readFileSync(filePath)
  if (buf.length === 0) return { text: '', frames: 0 }
  const starts = scanFrames(buf)
  // 未压缩的 session.jsonl（旧格式 / 测试夹具）直接按纯文本读
  if (starts.length === 0) return { text: buf.toString('utf8'), frames: 0 }
  let text = ''
  let frames = 0
  for (let f = 0; f < starts.length; f++) {
    const end = f + 1 < starts.length ? starts[f + 1] : buf.length
    try {
      text += zstdDecompressSync(buf.subarray(starts[f], end)).toString('utf8')
      frames++
    } catch {
      break // 正在写入的帧，下轮再读
    }
  }
  return { text, frames }
}

/**
 * 从日志文本里取每次模型调用：模型名 + token 用量 + 时间。
 * @returns {{model: string|null, time: number|null, input: number, output: number, cacheRead: number}[]}
 */
export function parseUsage(text) {
  const calls = []
  let model = null
  for (const line of text.split('\n')) {
    if (!line) continue
    let e
    try {
      e = JSON.parse(line)
    } catch {
      continue
    }
    const d = e && e.data
    if (!d || typeof d !== 'object') continue
    if (e.type === 'request/header' && d.header && d.header.config && d.header.config.model) {
      model = d.header.config.model
    } else if (e.type === 'request/context' && d.model) {
      model = d.model
    } else if (e.type === 'assistant/message' && d.usage && typeof d.usage === 'object') {
      const u = d.usage
      calls.push({
        model,
        time: typeof e.time === 'number' ? e.time : null,
        input: num(u.inputTokens),
        output: num(u.outputTokens),
        cacheRead: num(u.cacheReadTokens),
      })
    }
  }
  return calls
}

// ---------------------------------------------------------------------------
// 计价
// ---------------------------------------------------------------------------

/** 北京时间周一至周五 09:00-12:00、14:00-18:00 为高峰时段 */
export function isPeakTime(timeMs) {
  if (typeof timeMs !== 'number' || !Number.isFinite(timeMs)) return true
  const bj = new Date(timeMs + 8 * 3600_000)
  const day = bj.getUTCDay()
  const minutes = bj.getUTCHours() * 60 + bj.getUTCMinutes()
  if (day === 0 || day === 6) return false
  return (minutes >= 540 && minutes < 720) || (minutes >= 840 && minutes < 1080)
}

const ZERO_PRICE = { hit: 0, miss: 0, out: 0 }

/**
 * 本地部署的模型（不产生费用）：config.freeModels 里按名字匹配。
 * 支持通配：`glm-*` 表示以 glm- 开头的模型名。匹配时忽略大小写和 custom-local: 前缀。
 */
export function isFreeModel(model, cfg) {
  if (!model) return false
  const list = (cfg && cfg.freeModels) || []
  const name = String(model).toLowerCase().replace(/^custom-local:/, '')
  return list.some((pattern) => {
    const p = String(pattern).toLowerCase()
    return p.endsWith('*') ? name.startsWith(p.slice(0, -1)) : name === p
  })
}

/** 取某模型在某时刻的单价（元 / 百万 tokens）；本地免费模型返回全 0 价 */
export function priceFor(model, timeMs, cfg) {
  if (isFreeModel(model, cfg)) return ZERO_PRICE
  const prices = (cfg && cfg.prices) || {}
  const tier = prices.peakIdle && model ? prices.peakIdle[model] : null
  if (tier) return isPeakTime(timeMs) ? tier.peak : tier.idle
  return (prices.flat && model && prices.flat[model]) || null
}

/** 调用的唯一指纹：子代理 / 分支会话会把父会话的历史事件整段复制过来，用它去重 */
export function usageKey(call) {
  return `${call.time}|${call.model}|${call.input}|${call.output}|${call.cacheRead}`
}

/** 一次调用的估算花费 */
export function costForCall(call, timeMs, cfg) {
  const p = priceFor(call.model || cfg.defaultModel, timeMs, cfg)
  if (!p) return 0
  return (call.input * p.miss + call.cacheRead * p.hit + call.output * p.out) / 1_000_000
}

// ---------------------------------------------------------------------------
// 扫描与汇总
// ---------------------------------------------------------------------------

/** 所有会话日志：Map<sessionId, filePath> */
export function scanSessionFiles(cfg) {
  const root = path.join(cfg.dshDataDir, 'sessions')
  const out = new Map()
  let projects = []
  try {
    projects = fs.readdirSync(root, { withFileTypes: true })
  } catch {
    return out
  }
  for (const proj of projects) {
    if (!proj.isDirectory()) continue
    let sessions = []
    try {
      sessions = fs.readdirSync(path.join(root, proj.name), { withFileTypes: true })
    } catch {
      continue
    }
    for (const s of sessions) {
      if (!s.isDirectory()) continue
      for (const name of LOG_NAMES) {
        const p = path.join(root, proj.name, s.name, name)
        if (fs.existsSync(p)) {
          out.set(s.name, p)
          break
        }
      }
    }
  }
  return out
}

async function fetchBalance(cfg) {
  const key = cfg.apiKey
  if (!key) return { balance: null, error: '未配置 DeepSeek API Key，无法查询余额' }
  try {
    const res = await fetch('https://api.deepseek.com/user/balance', {
      headers: { Authorization: `Bearer ${key}`, Accept: 'application/json' },
      signal: AbortSignal.timeout(15_000),
    })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const data = await res.json()
    const infos = Array.isArray(data.balance_infos) ? data.balance_infos : []
    if (!infos.length) throw new Error('返回内容异常')
    const info = infos.find((x) => x.currency === 'CNY') || infos[0]
    return {
      balance: {
        currency: info.currency || 'CNY',
        totalBalance: info.total_balance ?? null,
        grantedBalance: info.granted_balance ?? null,
        toppedUpBalance: info.topped_up_balance ?? null,
        fetchedAt: Date.now(),
      },
      error: null,
    }
  } catch (err) {
    return { balance: null, error: `余额获取失败: ${String(err.message || err)}` }
  }
}

/** 汇总一次：本小时 / 今日 / 累计 花费 */
export async function collect(cfg) {
  const now = Date.now()
  const hourStart = localHourStart(now)
  const dayStart = localDayStart(now)
  const errors = []
  const missing = new Set()
  const stats = { sessions: 0, calls: 0, frames: 0 }
  const overall = { hour: 0, today: 0, total: 0 }
  const seen = new Set() // 跨会话去重（seeded 子代理会复制父会话的全部历史）

  for (const file of scanSessionFiles(cfg).values()) {
    let decoded
    try {
      decoded = decodeLogFile(file)
    } catch (err) {
      errors.push(`${path.basename(path.dirname(file))} 日志读取失败: ${err.message}`)
      continue
    }
    stats.sessions++
    stats.frames += decoded.frames

    let lastTime = null
    for (const call of parseUsage(decoded.text)) {
      const t = call.time ?? lastTime
      lastTime = t
      const key = usageKey(call)
      if (seen.has(key)) continue // 已由父会话 / 其它副本计入
      seen.add(key)
      stats.calls++
      const cost = costForCall(call, t, cfg)
      if (!priceFor(call.model || cfg.defaultModel, t, cfg)) missing.add(call.model || cfg.defaultModel)
      overall.total += cost
      if (t != null && t >= dayStart) overall.today += cost
      if (t != null && t >= hourStart) overall.hour += cost
    }
  }

  for (const model of [...missing].sort()) {
    errors.push(`模型 ${model} 没有配置单价，相关调用按 ¥0 计`)
  }

  return {
    generatedAt: now,
    hourStart,
    overall,
    errors,
    stats,
  }
}

// ---------------------------------------------------------------------------
// 主循环
// ---------------------------------------------------------------------------

export async function main() {
  const args = process.argv.slice(2)
  let configPath = DEFAULT_CONFIG_PATH
  let once = false
  let parentPid = null
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--config' && args[i + 1]) configPath = args[++i]
    else if (args[i] === '--once') once = true
    else if (args[i] === '--parent-pid' && args[i + 1]) parentPid = Number(args[++i])
  }

  let cfg
  try {
    cfg = JSON.parse(fs.readFileSync(configPath, 'utf8'))
  } catch (err) {
    console.error(`[DeepSeekSpend] 无法读取配置 ${configPath}: ${err.message}`)
    process.exit(2)
  }

  cfg.dshDataDir = expandHome(cfg.dshDataDir || process.env.DSH_HOME || path.join(os.homedir(), '.dsh'))
  cfg.snapshotPath = expandHome(cfg.snapshotPath)
  cfg.triggerPath = expandHome(cfg.triggerPath)
  cfg.pollIntervalMs = cfg.pollIntervalMs || 8000
  cfg.balanceIntervalMs = cfg.balanceIntervalMs || 300_000
  cfg.defaultModel = cfg.defaultModel || 'deepseek-flash'

  // 数据目录探测：配置值优先，其次 DSH_HOME
  for (const candidate of [cfg.dshDataDir, process.env.DSH_HOME]) {
    if (candidate && fs.existsSync(path.join(candidate, 'sessions'))) {
      cfg.dshDataDir = candidate
      break
    }
  }
  if (!cfg.apiKey) cfg.apiKey = readApiKey(path.join(cfg.dshDataDir, '.credentials.yaml'))

  let lastTriggerMtime = 0
  let cachedBalance = null
  let cachedBalanceError = null
  let balanceFetchedAt = 0

  const run = async (force) => {
    let triggerHit = force
    try {
      const tm = fs.statSync(cfg.triggerPath).mtimeMs
      if (tm > lastTriggerMtime) {
        lastTriggerMtime = tm
        triggerHit = true
      }
    } catch {}

    let snap
    try {
      snap = await collect(cfg)
    } catch (err) {
      snap = {
        generatedAt: Date.now(),
        hourStart: localHourStart(Date.now()),
        overall: { hour: 0, today: 0, total: 0 },
        balance: null,
        balanceError: null,
        errors: [`采集失败: ${err.message}`],
        stats: {},
      }
    }

    // 余额：首次、手动刷新、或到期时才请求，其余轮次复用缓存
    if (triggerHit || Date.now() - balanceFetchedAt >= cfg.balanceIntervalMs) {
      const { balance, error } = await fetchBalance(cfg)
      cachedBalance = balance
      cachedBalanceError = error
      balanceFetchedAt = Date.now()
    }
    snap.balance = cachedBalance
    snap.balanceError = cachedBalanceError

    fs.mkdirSync(path.dirname(cfg.snapshotPath), { recursive: true })
    const tmp = `${cfg.snapshotPath}.tmp`
    fs.writeFileSync(tmp, JSON.stringify(snap))
    fs.renameSync(tmp, cfg.snapshotPath)
    return snap
  }

  if (once) {
    await run(true)
    return
  }

  const ownerAlive = () => {
    if (parentPid) {
      try {
        process.kill(parentPid, 0)
        return true
      } catch {
        return false
      }
    }
    try {
      process.kill(process.ppid, 0)
      return true
    } catch {
      return false
    }
  }

  await run(true)
  const tick = async () => {
    if (!ownerAlive()) process.exit(0)
    try {
      await run(false)
    } catch (err) {
      console.error(`[DeepSeekSpend] 轮询失败: ${err.message}`)
    }
    setTimeout(tick, cfg.pollIntervalMs)
  }
  setTimeout(tick, cfg.pollIntervalMs)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error(`[DeepSeekSpend] 致命错误: ${err.stack || err}`)
    process.exit(1)
  })
}
