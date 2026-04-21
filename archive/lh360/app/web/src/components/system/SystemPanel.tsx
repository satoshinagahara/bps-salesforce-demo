import { useState } from 'react'
import type { PlanState } from '../../hooks/useChat'

interface Props {
  plan: PlanState | null
  isStreaming: boolean
}

const MODE_LABEL: Record<string, string> = {
  full: 'Full',
  atomic: 'Atomic',
  escalate: 'Escalate ☁️',
}

const MODE_COLOR: Record<string, string> = {
  full: 'bg-blue-900/50 text-blue-300 border-blue-700',
  atomic: 'bg-emerald-900/50 text-emerald-300 border-emerald-700',
  escalate: 'bg-purple-900/50 text-purple-300 border-purple-700',
}

function StepRow({ step, isActive }: { step: PlanState['steps'][0]; isActive: boolean }) {
  const icon =
    step.status === 'done' ? '✅' :
    step.status === 'running' ? '⚡' : '○'

  const modeClass = MODE_COLOR[step.mode] ?? 'bg-slate-800 text-slate-400 border-slate-600'

  return (
    <div className={`flex items-start gap-2 rounded-lg p-2 transition-colors ${isActive ? 'bg-slate-700/60' : ''}`}>
      <span className="mt-0.5 text-sm w-4 shrink-0">{icon}</span>
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-1.5 flex-wrap">
          <span className={`text-xs px-1.5 py-0.5 rounded border font-mono ${modeClass}`}>
            {MODE_LABEL[step.mode] ?? step.mode}
          </span>
          {step.elementary_id && (
            <span className="text-xs text-slate-500 font-mono">{step.elementary_id}</span>
          )}
        </div>
        <p className="text-xs text-slate-300 mt-0.5 leading-relaxed truncate" title={step.desc}>
          {step.desc}
        </p>
      </div>
    </div>
  )
}

export function SystemPanel({ plan, isStreaming }: Props) {
  const [open, setOpen] = useState(true)

  const hasContent = plan !== null || isStreaming

  return (
    <div className="flex flex-col h-full border-l border-slate-700">
      {/* ヘッダー */}
      <button
        onClick={() => setOpen(o => !o)}
        className="flex items-center justify-between px-3 py-2.5 border-b border-slate-700 hover:bg-slate-800 transition-colors text-left w-full"
      >
        <span className="text-xs font-semibold text-slate-400 uppercase tracking-wider">
          System View
        </span>
        <span className="text-slate-500 text-sm">{open ? '▶' : '◀'}</span>
      </button>

      {!open && (
        <div className="flex-1 flex items-center justify-center">
          <span className="text-slate-600 text-xs [writing-mode:vertical-rl]">System View</span>
        </div>
      )}

      {open && (
        <div className="flex-1 overflow-y-auto px-3 py-3 space-y-4">
          {!hasContent && (
            <p className="text-xs text-slate-600 text-center mt-8">
              エージェントが動き始めると<br />プランがここに表示されます
            </p>
          )}

          {isStreaming && !plan && (
            <div className="flex items-center gap-2 text-xs text-slate-400">
              <span className="animate-pulse">●</span>
              Planner 起動中…
            </div>
          )}

          {plan && (
            <>
              {/* プランヘッダー */}
              <div>
                <div className="flex items-center gap-2 mb-1">
                  <span className={`text-xs px-1.5 py-0.5 rounded border ${
                    plan.classification === 'complex'
                      ? 'bg-amber-900/40 text-amber-300 border-amber-700'
                      : 'bg-slate-800 text-slate-400 border-slate-600'
                  }`}>
                    {plan.classification === 'complex' ? '複合プラン' : 'シンプル'}
                  </span>
                  {plan.fallback && (
                    <span className="text-xs text-orange-400">⚠ fallback</span>
                  )}
                </div>
                <p className="text-xs text-slate-400 leading-relaxed">{plan.user_intent}</p>
              </div>

              {/* ステップリスト */}
              <div>
                <p className="text-xs text-slate-500 mb-1.5">
                  Steps ({plan.steps.length})
                </p>
                <div className="space-y-0.5">
                  {plan.steps.map(step => (
                    <StepRow
                      key={step.step_id}
                      step={step}
                      isActive={step.step_id === plan.activeStepId}
                    />
                  ))}
                </div>
              </div>

              {/* synthesis hint */}
              {plan.synthesis_hint && (
                <div className="rounded-lg border border-slate-700 bg-slate-800/40 px-3 py-2">
                  <p className="text-xs text-slate-500 mb-0.5">Synthesis</p>
                  <p className="text-xs text-slate-400">{plan.synthesis_hint}</p>
                </div>
              )}
            </>
          )}
        </div>
      )}
    </div>
  )
}
