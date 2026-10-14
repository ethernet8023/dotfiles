import type {Model, Status} from './model.js';

/** The native menu's items, in its order. `All` is not a status, it is the select-all row */
export const filterLabels = [
	'Queued',
	'In progress',
	'Action required',
	'Successful',
	'Failed',
	'Cancelled',
	'Skipped',
	'Timed out',
] as const;

export type FilterLabel = typeof filterLabels[number];

/** Statuses the user has switched OFF. Empty means "All jobs" */
export type Excluded = ReadonlySet<string>;

/** Most runs are mostly noise from skipped jobs, so start without them */
export const defaultExcluded: Excluded = new Set<string>(['Skipped']);

/** Which menu item controls a job, if any. `Unknown` is never hidden: we cannot show it again if we do not know what it is */
export function filterLabelOf(status: Status): FilterLabel | undefined {
	if (status === 'Unknown') {
		return undefined;
	}

	// A job that is waiting on its dependencies has not started either; the menu has no row of its own for it
	return status === 'Waiting' ? 'Queued' : status;
}

export function isVisible(status: Status, excluded: Excluded): boolean {
	const label = filterLabelOf(status);
	return !label || !excluded.has(label);
}

/**
 * Applies a click on a menu row. `All` behaves like a select-all checkbox:
 * if everything is already on it switches everything off, otherwise it switches everything on.
 */
export function toggleExcluded(excluded: Excluded, label: string): Excluded {
	if (label === 'All') {
		return excluded.size === 0 ? new Set(filterLabels) : new Set();
	}

	if (!(filterLabels as readonly string[]).includes(label)) {
		return excluded;
	}

	const next = new Set(excluded);
	if (!next.delete(label)) {
		next.add(label);
	}

	return next;
}

/** A click on a row's "only" link: everything off except that one status */
export function onlyExcluded(excluded: Excluded, label: string): Excluded {
	if (!(filterLabels as readonly string[]).includes(label)) {
		return excluded;
	}

	return new Set(filterLabels.filter(other => other !== label));
}

/** The sidebar heading. Names whichever of "all except X" and "only Y" is shorter */
export function getTitle(excluded: Excluded): string {
	if (excluded.size === 0) {
		return 'All jobs';
	}

	const checked = filterLabels.filter(label => !excluded.has(label));
	if (checked.length === 0) {
		return 'No jobs';
	}

	const excludedText = `All jobs except ${filterLabels.filter(label => excluded.has(label)).join(', ')}`;
	const includedText = `${checked.join(', ')} jobs`;
	return excludedText.length > includedText.length ? includedText : excludedText;
}

/**
 * Drops hidden jobs, then cards left with nothing in them.
 * A card with no jobs at all is a matrix that has not expanded yet ("Waiting for pending jobs"), so it counts as waiting.
 * Edges through a removed card are NOT stitched back together: a hidden job did not "pass" anything on.
 */
export function filterModel(model: Model, excluded: Excluded): Model {
	if (excluded.size === 0) {
		return model;
	}

	const cards = model.cards.flatMap(card => {
		if (card.jobs.length === 0) {
			return isVisible('Waiting', excluded) ? [card] : [];
		}

		const jobs = card.jobs.filter(job => isVisible(job.status, excluded));
		return jobs.length > 0 ? [{...card, jobs}] : [];
	});

	const kept = new Set(cards.map(card => card.id));
	return {
		cards,
		edges: model.edges.filter(([from, to]) => kept.has(from) && kept.has(to)),
	};
}
