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
		<div className="dr-questions">
			<div className="q-title">{APP_COPY.questionsTitle} · {questions.length}</div>
			{questions.map((q) => (
				<div key={q.id} className="q-item">
					<QuestionCard question={q} />
				</div>
			))}
		</div>
	);
}
