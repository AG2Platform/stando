import QuestionCard from '@/components/molecules/question-card';
import { APP_COPY } from '@/const-values/app-copy';
import { useTasks } from '@/hooks/useTasks';

/**
 * Pending-questions organism. Renders nothing when no questions are
 * outstanding — keeps the conversation page quiet by default. The polling
 * hook (driven by <TaskList />) keeps this in sync.
 */
export default function QuestionsPanel() {
	const { questions } = useTasks();
	if (questions.length === 0) return null;

	return (
		<section className="rounded-lg border border-amber-500/30 bg-amber-500/[0.04] p-4">
			<header className="mb-3 flex items-center gap-2">
				<h2 className="text-sm font-semibold text-amber-200">{APP_COPY.questionsTitle}</h2>
				<span className="rounded-full bg-amber-500/15 px-2 py-0.5 text-[11px] uppercase tracking-wide text-amber-200">
					{questions.length}
				</span>
			</header>
			<div className="space-y-2">
				{questions.map((q) => (
					<QuestionCard key={q.id} question={q} />
				))}
			</div>
		</section>
	);
}
