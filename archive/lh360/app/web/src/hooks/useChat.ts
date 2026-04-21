/**
 * useChat — SSE ストリームで Orchestrator イベントを受け取るフック。
 *
 * POST /chat → fetch + ReadableStream で SSE を受信。
 * (ブラウザ標準の EventSource は GET only のため fetch で代替)
 */
import { useCallback, useEffect, useRef, useState } from 'react'

export type MessageRole = 'user' | 'assistant'

export interface ChatMessage {
  id: string
  role: MessageRole
  content: string
  toolCalls?: ToolCall[]
}

export interface ToolCall {
  id: string
  name: string
  arguments: Record<string, unknown>
  result?: string
  isError?: boolean
  elapsed?: number
  status: 'pending' | 'done' | 'error'
}

export interface PlanStep {
  step_id: string
  mode: string
  elementary_id: string | null
  desc: string
  status: 'pending' | 'running' | 'done'
}

export interface PlanState {
  plan_id: string
  user_intent: string
  classification: string
  steps: PlanStep[]
  synthesis_hint: string
  fallback: boolean
  activeStepId: string | null
}

export function useChat() {
  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [plan, setPlan] = useState<PlanState | null>(null)
  const [isStreaming, setIsStreaming] = useState(false)
  const abortRef = useRef<AbortController | null>(null)
  // sendMessage 内で最新の messages を参照するための ref。
  // useCallback の依存配列から messages を外すことで、
  // メッセージ到着ごとの関数再生成を防ぐ。
  const messagesRef = useRef(messages)
  // useEffect 内で ref を同期（レンダリング中の ref 更新は ESLint react-hooks/refs 違反）
  useEffect(() => { messagesRef.current = messages }, [messages])

  const sendMessage = useCallback(async (text: string) => {
    if (!text.trim() || isStreaming) return

    const userMsg: ChatMessage = { id: crypto.randomUUID(), role: 'user', content: text }
    setMessages(prev => [...prev, userMsg])
    setIsStreaming(true)
    setPlan(null)

    const asstId = crypto.randomUUID()
    const asstMsg: ChatMessage = { id: asstId, role: 'assistant', content: '', toolCalls: [] }
    setMessages(prev => [...prev, asstMsg])

    // 履歴は ref から取得（userMsg 追加前のスナップショット）
    const history = messagesRef.current
      .filter(m => m.role === 'user' || (m.role === 'assistant' && m.content))
      .map(m => ({ role: m.role, content: m.content }))

    abortRef.current = new AbortController()

    try {
      const res = await fetch('/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ message: text, history }),
        signal: abortRef.current.signal,
      })

      if (!res.ok || !res.body) {
        throw new Error(`HTTP ${res.status}`)
      }

      const reader = res.body.getReader()
      const decoder = new TextDecoder()
      let buf = ''

      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        buf += decoder.decode(value, { stream: true })

        // SSE パース: sse-starlette は CRLF で送出するため正規化
        buf = buf.replace(/\r\n/g, '\n')
        const blocks = buf.split('\n\n')
        buf = blocks.pop() ?? ''

        for (const block of blocks) {
          if (!block.trim()) continue
          const parsed = parseSSEBlock(block)
          if (parsed) {
            handleEvent(parsed.event, parsed.data, asstId, setPlan, setMessages)
          }
        }
      }
    } catch (e: unknown) {
      if (e instanceof Error && e.name === 'AbortError') return
      setMessages(prev => prev.map(m =>
        m.id === asstId
          ? { ...m, content: m.content + '\n\n_(エラーが発生しました)_' }
          : m
      ))
    } finally {
      setIsStreaming(false)
      abortRef.current = null
    }
  }, [isStreaming])

  const stop = useCallback(() => {
    abortRef.current?.abort()
    setIsStreaming(false)
  }, [])

  const reset = useCallback(() => {
    stop()
    setMessages([])
    setPlan(null)
  }, [stop])

  return { messages, plan, isStreaming, sendMessage, stop, reset }
}

// ---- SSE パーサ ----

/** SSE ブロック1個をパースする。data: が複数行に跨る場合も連結する（SSE 仕様準拠）。 */
function parseSSEBlock(block: string): { event: string; data: Record<string, unknown> } | null {
  const lines = block.split('\n')
  let eventName = 'message'
  const dataLines: string[] = []

  for (const line of lines) {
    if (line.startsWith('event:')) {
      eventName = line.slice(6).trim()
    } else if (line.startsWith('data:')) {
      dataLines.push(line.slice(5).trimStart())
    }
    // id:, retry:, comment(:) は無視
  }

  if (dataLines.length === 0) return null
  const dataStr = dataLines.join('\n')
  try {
    return { event: eventName, data: JSON.parse(dataStr) }
  } catch {
    return null
  }
}

// ---- イベントハンドラ ----

function handleEvent(
  event: string,
  data: Record<string, unknown>,
  asstId: string,
  setPlan: React.Dispatch<React.SetStateAction<PlanState | null>>,
  setMessages: React.Dispatch<React.SetStateAction<ChatMessage[]>>,
) {
  switch (event) {
    case 'plan_created': {
      const steps = (data.steps as PlanStep[]).map(s => ({ ...s, status: 'pending' as const }))
      setPlan({
        plan_id: data.plan_id as string,
        user_intent: data.user_intent as string,
        classification: data.classification as string,
        steps,
        synthesis_hint: data.synthesis_hint as string,
        fallback: data.fallback as boolean,
        activeStepId: null,
      })
      break
    }
    case 'step_start': {
      setPlan(prev => {
        if (!prev) return prev
        return {
          ...prev,
          activeStepId: data.step_id as string,
          steps: prev.steps.map(s =>
            s.step_id === data.step_id ? { ...s, status: 'running' } : s
          ),
        }
      })
      break
    }
    case 'step_end': {
      setPlan(prev => {
        if (!prev) return prev
        return {
          ...prev,
          activeStepId: null,
          steps: prev.steps.map(s =>
            s.step_id === data.step_id ? { ...s, status: 'done' } : s
          ),
        }
      })
      break
    }
    case 'tool_start': {
      const toolCall: ToolCall = {
        id: data.id as string,
        name: data.name as string,
        arguments: data.arguments as Record<string, unknown>,
        status: 'pending',
      }
      setMessages(prev => prev.map(m =>
        m.id === asstId
          ? { ...m, toolCalls: [...(m.toolCalls ?? []), toolCall] }
          : m
      ))
      break
    }
    case 'tool_result': {
      setMessages(prev => prev.map(m =>
        m.id === asstId
          ? {
              ...m,
              toolCalls: (m.toolCalls ?? []).map(tc =>
                tc.id === data.id
                  ? {
                      ...tc,
                      result: data.result_summary as string,
                      isError: data.is_error as boolean,
                      elapsed: data.elapsed as number,
                      status: (data.is_error ? 'error' : 'done') as ToolCall['status'],
                    }
                  : tc
              ),
            }
          : m
      ))
      break
    }
    case 'text': {
      setMessages(prev => prev.map(m =>
        m.id === asstId ? { ...m, content: m.content + (data.text as string) } : m
      ))
      break
    }
    case 'finish':
    case 'error':
      break
  }
}
