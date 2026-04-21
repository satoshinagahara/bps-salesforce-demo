import { useEffect, useRef, useState } from 'react'
import type { ChatMessage } from '../../hooks/useChat'
import { MessageBubble } from './MessageBubble'

interface Props {
  messages: ChatMessage[]
  isStreaming: boolean
  onSend: (text: string) => void
  onStop: () => void
  onReset: () => void
}

export function ChatPanel({ messages, isStreaming, onSend, onStop, onReset }: Props) {
  const [input, setInput] = useState('')
  const [examples, setExamples] = useState<string[]>([])
  const bottomRef = useRef<HTMLDivElement>(null)
  const textareaRef = useRef<HTMLTextAreaElement>(null)

  // サンプル発話をバックエンドから取得（マウント時1回）
  useEffect(() => {
    fetch('/chat/examples')
      .then(r => r.json())
      .then((d: { examples: string[] }) => setExamples(d.examples))
      .catch(() => {})
  }, [])

  // 新メッセージ到着時に自動スクロール
  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages])

  const handleSubmit = () => {
    const text = input.trim()
    if (!text || isStreaming) return
    setInput('')
    onSend(text)
  }

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      handleSubmit()
    }
  }

  return (
    <div className="flex flex-col h-full">
      {/* メッセージリスト */}
      <div className="flex-1 overflow-y-auto px-4 py-4 space-y-3">
        {messages.length === 0 ? (
          <div className="flex flex-col items-center justify-center h-full gap-6 text-center">
            <div>
              <p className="text-2xl font-semibold text-slate-100">Local Headless 360</p>
              <p className="text-sm text-slate-400 mt-1">Gemma 4 × Claude Sonnet — Salesforce AI Agent</p>
            </div>
            <div className="grid grid-cols-1 gap-2 w-full max-w-md">
              {examples.map(ex => (
                <button
                  key={ex}
                  onClick={() => onSend(ex)}
                  className="text-left rounded-xl border border-slate-700 bg-slate-800/60 px-4 py-2.5 text-sm text-slate-300 hover:bg-slate-700 transition-colors"
                >
                  {ex}
                </button>
              ))}
            </div>
          </div>
        ) : (
          messages.map(m => <MessageBubble key={m.id} message={m} />)
        )}
        <div ref={bottomRef} />
      </div>

      {/* 入力エリア */}
      <div className="border-t border-slate-700 px-4 py-3">
        <div className="flex gap-2 items-end">
          <textarea
            ref={textareaRef}
            value={input}
            onChange={e => setInput(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="メッセージを入力… (Enter で送信 / Shift+Enter で改行)"
            rows={2}
            disabled={isStreaming}
            className="flex-1 resize-none rounded-xl border border-slate-600 bg-slate-800 px-3 py-2 text-sm text-slate-100 placeholder:text-slate-500 focus:outline-none focus:border-indigo-500 disabled:opacity-50"
          />
          <div className="flex flex-col gap-1">
            {isStreaming ? (
              <button
                onClick={onStop}
                className="rounded-xl bg-red-600 hover:bg-red-500 px-3 py-2 text-sm text-white transition-colors"
              >
                停止
              </button>
            ) : (
              <button
                onClick={handleSubmit}
                disabled={!input.trim()}
                className="rounded-xl bg-indigo-600 hover:bg-indigo-500 px-3 py-2 text-sm text-white transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
              >
                送信
              </button>
            )}
            {messages.length > 0 && !isStreaming && (
              <button
                onClick={onReset}
                className="rounded-xl border border-slate-600 px-3 py-1.5 text-xs text-slate-400 hover:bg-slate-700 transition-colors"
              >
                クリア
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}
