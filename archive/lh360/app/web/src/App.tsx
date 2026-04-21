import { useChat } from './hooks/useChat'
import { ChatPanel } from './components/chat/ChatPanel'
import { SystemPanel } from './components/system/SystemPanel'

export default function App() {
  const { messages, plan, isStreaming, sendMessage, stop, reset } = useChat()

  return (
    <div className="flex flex-col h-dvh bg-slate-900 text-slate-100">
      {/* ヘッダー */}
      <header className="shrink-0 flex items-center justify-between px-4 py-2.5 border-b border-slate-700 bg-slate-900/90 backdrop-blur">
        <div className="flex items-center gap-2">
          <span className="text-base font-semibold text-slate-100">Local Headless 360</span>
          <span className="text-xs text-slate-500">Gemma 4 × Claude Sonnet</span>
        </div>
        <div className="flex items-center gap-1.5 text-xs text-slate-400">
          {isStreaming && (
            <span className="flex items-center gap-1 text-indigo-400">
              <span className="animate-pulse">●</span>
              応答中
            </span>
          )}
        </div>
      </header>

      {/* メインエリア */}
      <div className="flex flex-1 min-h-0">
        {/* チャットパネル（左・主） */}
        <main className="flex-1 min-w-0">
          <ChatPanel
            messages={messages}
            isStreaming={isStreaming}
            onSend={sendMessage}
            onStop={stop}
            onReset={reset}
          />
        </main>

        {/* システムビュー（右・サイドパネル） */}
        <aside className="w-64 shrink-0">
          <SystemPanel plan={plan} isStreaming={isStreaming} />
        </aside>
      </div>
    </div>
  )
}
