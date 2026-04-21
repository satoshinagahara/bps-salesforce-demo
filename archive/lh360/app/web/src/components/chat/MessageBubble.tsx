import type { ChatMessage, ToolCall } from '../../hooks/useChat'

interface Props {
  message: ChatMessage
}

function ToolCallBlock({ tc }: { tc: ToolCall }) {
  const icon = tc.status === 'pending' ? '⏳' : tc.isError ? '❌' : '✅'
  const argsStr = JSON.stringify(tc.arguments, null, 2)
  const truncArgs = argsStr.length > 300 ? argsStr.slice(0, 300) + '\n…' : argsStr

  return (
    <details className="mt-1 rounded border border-white/10 bg-white/5 text-xs">
      <summary className="cursor-pointer px-3 py-2 text-slate-300 select-none">
        {icon} <span className="font-mono">{tc.name}</span>
        {tc.elapsed !== undefined && (
          <span className="ml-2 text-slate-500">{tc.elapsed}s</span>
        )}
      </summary>
      <div className="px-3 pb-2 space-y-1">
        <pre className="text-slate-400 overflow-x-auto whitespace-pre-wrap">{truncArgs}</pre>
        {tc.result && (
          <>
            <div className="text-slate-500 border-t border-white/10 pt-1">Result:</div>
            <pre className="text-slate-300 overflow-x-auto whitespace-pre-wrap">
              {tc.result.length > 600 ? tc.result.slice(0, 600) + '\n…' : tc.result}
            </pre>
          </>
        )}
      </div>
    </details>
  )
}

export function MessageBubble({ message }: Props) {
  const isUser = message.role === 'user'

  if (isUser) {
    return (
      <div className="flex justify-end">
        <div className="max-w-[75%] rounded-2xl rounded-tr-sm bg-indigo-600 px-4 py-2.5 text-sm text-white">
          {message.content}
        </div>
      </div>
    )
  }

  return (
    <div className="flex justify-start">
      <div className="max-w-[85%] space-y-1">
        {/* ツール呼び出し群 */}
        {message.toolCalls && message.toolCalls.length > 0 && (
          <div className="space-y-1">
            {message.toolCalls.map(tc => (
              <ToolCallBlock key={tc.id} tc={tc} />
            ))}
          </div>
        )}

        {/* アシスタントテキスト */}
        {message.content && (
          <div className="rounded-2xl rounded-tl-sm bg-slate-800 px-4 py-2.5 text-sm text-slate-100 whitespace-pre-wrap">
            {message.content}
          </div>
        )}

        {/* テキストも tool もない = thinking 中 */}
        {!message.content && (!message.toolCalls || message.toolCalls.length === 0) && (
          <div className="rounded-2xl rounded-tl-sm bg-slate-800 px-4 py-2.5 text-sm text-slate-400 italic">
            考えています…
          </div>
        )}
      </div>
    </div>
  )
}
