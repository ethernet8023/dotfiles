import type {Card} from './model.js';

const tokenPattern = /[\p{L}\p{N}_.+:-]+|\s+|[^\p{L}\p{N}_.+:\s-]/gu;
const closerOf: Readonly<Record<string, string>> = {'(': ')', '[': ']'};

export type Compacted = {
	/** Said once in the card header: the workflow every job shares, and the name stem they all start with */
	note: string | undefined;
	/** One per job: what is left of its name once the stem is gone */
	labels: string[];
	/** One per job: its own workflow, or undefined when the header already says it */
	workflows: Array<string | undefined>;
};

function hasLetterOrDigit(text: string): boolean {
	return /[\p{L}\p{N}]/u.test(text);
}

function isBalanced(text: string): boolean {
	let depth = 0;
	for (const character of text) {
		if (character === '(' || character === '[') {
			depth++;
		} else if (character === ')' || character === ']') {
			depth--;
			if (depth < 0) {
				return false;
			}
		}
	}

	return depth === 0;
}

/**
 * Splits names into the words they all start with and what differs, on whole words only:
 * `Build and test image (desktop/amd64)` + `Build and test image (slim/arm64)` -> stem `Build and test image`, rests `desktop/amd64` and `slim/arm64`.
 * Returns undefined when stripping would be unsafe or pointless: duplicate names, a stem that is just punctuation, or a bracket left open.
 */
export function splitStem(names: string[]): {stem: string; rests: string[]} | undefined {
	if (names.length < 2 || new Set(names).size !== names.length) {
		return undefined;
	}

	const lists = names.map(name => name.match(tokenPattern) ?? []);
	const first = lists[0]!;
	const minLength = Math.min(...lists.map(list => list.length));

	// Leave at least one token of every name, so no job ends up with an empty label
	let shared = 0;
	while (shared < minLength - 1 && lists.every(list => list[shared] === first[shared])) {
		shared++;
	}

	// A stem that ends in "(" takes the closing ")" with it, but only if every name ends with one; otherwise the bracket stays in the labels
	const closer = closerOf[first[shared - 1] ?? ''];
	const pairsBracket = closer !== undefined && lists.every(list => list.at(-1) === closer);
	if (closer !== undefined && !pairsBracket) {
		shared--;
	}

	if (shared <= 0) {
		return undefined;
	}

	const stem = first.slice(0, pairsBracket ? shared - 1 : shared).join('').trim().replace(/[\s([:/\-–·]+$/u, '');
	const rests = lists.map(list => list.slice(shared, pairsBracket ? -1 : undefined).join('').trim());

	const letters = [...stem].filter(character => /[\p{L}\p{N}]/u.test(character)).length;
	if (letters < 3 || !rests.every(rest => hasLetterOrDigit(rest) && isBalanced(rest))) {
		return undefined;
	}

	return {stem, rests};
}

const pathSeparator = ' / ';

/** The leading workflow path segments every job has: `A / B / C` and `A / B / D` -> [`A`, `B`] */
function commonPath(workflows: Array<string | undefined>): string[] {
	if (workflows.length < 2 || workflows.some(workflow => !workflow)) {
		return [];
	}

	const paths = workflows.map(workflow => workflow!.split(pathSeparator));
	const common: string[] = [];
	for (const [index, segment] of paths[0]!.entries()) {
		if (!paths.every(path => path[index] === segment)) {
			break;
		}

		common.push(segment);
	}

	return common;
}

/**
 * The repeated parts of a card say it once: a matrix of ten jobs from `Full CI pipeline` should not print `Full CI pipeline` ten times.
 * Cards of one job are left exactly as GitHub names them.
 */
export function compactCard(card: Card): Compacted {
	const {jobs} = card;
	const split = splitStem(jobs.map(job => job.name));

	const shared = commonPath(jobs.map(job => job.workflow));
	const sharedPath = shared.join(pathSeparator);
	// A matrix title already says it ("Matrix: Docker build and tests / build"), so saying it again is noise
	const pathInNote = sharedPath && !card.title?.includes(sharedPath) ? sharedPath : undefined;

	return {
		note: [pathInNote, split?.stem].filter(Boolean).join(' · ') || undefined,
		labels: split ? split.rests : jobs.map(job => job.name),
		// What is left of each job's own path once the shared start is gone: the part that tells the jobs apart
		workflows: jobs.map(job => {
			if (shared.length === 0) {
				return job.workflow;
			}

			return job.workflow!.split(pathSeparator).slice(shared.length).join(pathSeparator) || undefined;
		}),
	};
}
