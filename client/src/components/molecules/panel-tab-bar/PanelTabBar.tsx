import PanelTab, { type PanelTabUnseen } from '@/components/atoms/panel-tab';

/**
 * Segmented tab strip rendered at the top of the conversation panels
 * card. Visual replacement for the legacy `.dr-tabs` row — same tab ids,
 * but rendered as pill segments with a "active" surface tint.
 */

export interface PanelTabDef {
	id: string;
	label: string;
	count?: number;
	unseen?: PanelTabUnseen;
}

export interface PanelTabBarProps {
	tabs: readonly PanelTabDef[];
	activeId: string;
	onSelect: (id: string) => void;
}

export default function PanelTabBar({ tabs, activeId, onSelect }: PanelTabBarProps) {
	return (
		<div
			role="tablist"
			className="flex gap-1 rounded-2xl bg-(--surface-elev)/70 p-1"
		>
			{tabs.map((tab) => (
				<PanelTab
					key={tab.id}
					id={tab.id}
					label={tab.label}
					count={tab.count}
					unseen={tab.unseen ?? null}
					isActive={tab.id === activeId}
					onSelect={onSelect}
				/>
			))}
		</div>
	);
}
