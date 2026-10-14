/**
 * The first eight are GitHub's own filter labels, spelled exactly like the native menu items.
 * `Waiting` is a job that has not started because something it needs has not finished: the graph shows it, the sidebar does not.
 */
export type Status =
	| 'Queued'
	| 'In progress'
	| 'Action required'
	| 'Successful'
	| 'Failed'
	| 'Cancelled'
	| 'Skipped'
	| 'Timed out'
	| 'Waiting'
	| 'Unknown';

export type Job = {
	name: string;
	href: string | undefined;
	status: Status;
	/** A collapsed matrix ("4 jobs completed") is one box standing for several jobs */
	count: number;
	/** GitHub's own text, e.g. "2m 48s". Absent while the job has not finished */
	duration: string | undefined;
	/** The parent workflow, for a job from a reusable workflow: "Build signed release candidates (darwin-arm64)" */
	workflow: string | undefined;
};

/** One box in GitHub's graph: a single job, a group of jobs, or a not-yet-expanded matrix */
export type Card = {
	id: string;
	title: string | undefined;
	jobs: Job[];
};

export type Model = {
	cards: Card[];
	/** [from, to] card ids */
	edges: Array<[string, string]>;
};

export type RawJob = {
	name: string;
	href: string | null;
	/** Every class on the status `<svg>`, space separated */
	icon: string | null;
	/** The `<svg>`'s aria-label, e.g. "skipped: " */
	label: string | null;
	/** How many jobs this box stands for. Defaults to 1 */
	count?: number;
	duration?: string | null;
	workflow?: string | null;
};

export type RawCard = {
	id: string;
	title: string | null;
	jobs: RawJob[];
};

/**
 * Worst first. A card of several jobs takes the colour of its most urgent one, so a single failure
 * is not drowned out by a dozen green jobs next to it. `Waiting` and `Unknown` are last: nothing has happened yet.
 */
const urgency: readonly Status[] = [
	'Failed',
	'Timed out',
	'Action required',
	'Cancelled',
	'In progress',
	'Queued',
	'Successful',
	'Skipped',
	'Waiting',
	'Unknown',
];

/** The most urgent status among `statuses`, or undefined when there are none */
export function worstStatus(statuses: readonly Status[]): Status | undefined {
	let worst: Status | undefined;
	for (const status of statuses) {
		if (worst === undefined || urgency.indexOf(status) < urgency.indexOf(worst)) {
			worst = status;
		}
	}

	return worst;
}

const statusByAriaPrefix: ReadonlyArray<[prefix: string, status: Status]> = [
	['completed successfully', 'Successful'],
	['failed', 'Failed'],
	['skipped', 'Skipped'],
	['cancelled', 'Cancelled'],
	['currently running', 'In progress'],
	['timed out', 'Timed out'],
];

const statusByIconClass: ReadonlyArray<[className: string, status: Status]> = [
	['octicon-check-circle-fill', 'Successful'],
	['octicon-x-circle-fill', 'Failed'],
	['octicon-skip', 'Skipped'],
	['octicon-stop', 'Cancelled'],
	['octicon-bell', 'Action required'],
	['octicon-alert', 'Timed out'],
	['octicon-dot-fill', 'Queued'],
	['anim-rotate', 'In progress'],
	// Exact class match, so it cannot catch `octicon-check-circle-fill`
	['octicon-circle', 'Waiting'],
];

export function statusOfJob(icon: string | null, ariaLabel: string | null): Status {
	const label = ariaLabel?.trim().toLowerCase() ?? '';
	for (const [prefix, status] of statusByAriaPrefix) {
		if (label.startsWith(prefix)) {
			return status;
		}
	}

	const classes = new Set(icon?.split(/\s+/) ?? []);
	for (const [className, status] of statusByIconClass) {
		if (classes.has(className)) {
			return status;
		}
	}

	return 'Unknown';
}

/**
 * A graph job's tooltip holds the whole path ("Workflow / Smoke Windows arm64 MSIX / Job"), where the link text shows "Workflow / ... / Job".
 * Returns everything before the job's own name, or undefined when the tooltip does not end in `name` on a "/" boundary.
 */
export function workflowFromTooltip(tooltip: string | null | undefined, name: string): string | undefined {
	const text = tooltip?.replaceAll(/\s+/g, ' ').trim();
	if (!text || name === '' || !text.endsWith(name)) {
		return undefined;
	}

	const prefix = text.slice(0, text.length - name.length);
	if (!/\/\s*$/.test(prefix)) {
		return undefined;
	}

	return prefix.replace(/\s*\/\s*$/, '').trim() || undefined;
}

/** "4 jobs completed", "0/1 jobs completed", "1/11 job completed" -> how many jobs the matrix holds (4, 1, 11) */
export function parseMatrixSummary(text: string): number {
	const match = /(?:\d+\/)?(\d+)\s+jobs?\b/i.exec(text);
	return match ? Number.parseInt(match[1]!, 10) : 1;
}

export function buildModel(rawCards: RawCard[], rawEdges: Array<[string, string]>): Model {
	const cards: Card[] = rawCards.map(card => ({
		id: card.id,
		title: card.title ?? undefined,
		jobs: card.jobs.map(job => ({
			name: job.name,
			href: job.href ?? undefined,
			status: statusOfJob(job.icon, job.label),
			count: job.count ?? 1,
			duration: job.duration ?? undefined,
			workflow: job.workflow ?? undefined,
		})),
	}));

	const known = new Set(cards.map(card => card.id));
	const edges = rawEdges.filter(([from, to]) => from !== to && known.has(from) && known.has(to));
	return {cards, edges};
}

export function countJobs(model: Model): number {
	return model.cards.reduce((total, card) => total + card.jobs.reduce((sum, job) => sum + job.count, 0), 0);
}

/**
 * Drops an edge when a longer path already connects its ends (transitive reduction).
 * Workflows often make every job `needs: setup` as well as `needs: previous-job`; the direct edge adds a line but no information.
 */
export function reduceEdges(model: Model): Model {
	const next = new Map<string, string[]>();
	for (const [from, to] of model.edges) {
		next.set(from, [...next.get(from) ?? [], to]);
	}

	/** Is `target` reachable from `start` without taking the direct start->target edge? */
	const hasLongerPath = (start: string, target: string): boolean => {
		const seen = new Set<string>([start]);
		const stack = (next.get(start) ?? []).filter(id => id !== target);
		while (stack.length > 0) {
			const id = stack.pop()!;
			if (id === target) {
				return true;
			}

			if (seen.has(id)) {
				continue;
			}

			seen.add(id);
			stack.push(...next.get(id) ?? []);
		}

		return false;
	};

	return {
		cards: model.cards,
		edges: model.edges.filter(([from, to]) => !hasLongerPath(from, to)),
	};
}
