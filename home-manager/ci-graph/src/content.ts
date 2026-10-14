import {defaultExcluded, type Excluded, filterModel, getTitle, isVisible, onlyExcluded, toggleExcluded} from './filter.js';
import {createCanvasMeasures, layoutModel, type Measures} from './layout.js';
import {buildModel, countJobs, type Model, parseMatrixSummary, reduceEdges, type RawCard, type RawJob, statusOfJob, workflowFromTooltip} from './model.js';
import {renderLayout} from './render.js';
import {createViewer, type Viewer} from './viewport.js';

const filteringClass = 'cig-filtering';
const matchClass = 'cig-match';
const mountClass = 'cig-mount';
const onlyClass = 'cig-only';

/** Every selector that touches GitHub's DOM is here; if the page changes, fix it here */
const selectors = {
	graph: '.WorkflowGraph',
	card: '.WorkflowCard',
	job: 'streaming-graph-job',
	jobLink: 'a.WorkflowJob-title',
	cardTitle: '.WorkflowCard-heading--content',
	jobNameParts: 'span.css-truncate-overflow',
	jobDuration: '.flex-self-baseline.text-small',
	connector: 'path.WorkflowConnector',
	collapsedMatrix: '.js-graph-matrix button[data-action*="expandMatrix"]',
	filterButton: '[class^="ActionsRunJobsList-module__jobsHeader"] button:has(.octicon-filter)',
	heading: '[class^="ActionsRunJobsList-module__jobsHeading"]',
	sidebarJobLink: 'nav[aria-label="Workflow run"] a[data-test-selector="job-link"]',
	sidebarIcon: '[data-component="ActionList.LeadingVisual"] svg',
	menu: '[role="menu"]',
	menuItem: '[role="menuitemradio"]',
	menuItemLabel: '[data-component="ActionList.Item.Label"]',
} as const;

type State = {
	excluded: Excluded;
	lastSignature: string | undefined;
	viewer: Viewer;
	firstDraw: boolean;
	measures: Measures | undefined;
	/** Matrix jobs fetched from GitHub, by matrix key (update URL + summary text, so a changed summary fetches again) */
	expanded: Map<string, RawJob[]>;
	/** Keys already requested. Never cleared, so a failed request is not retried on every redraw */
	requested: Set<string>;
	onExpanded: () => void;
};

/** The pieces of a graph job link: `<span>Workflow&nbsp;</span> / <span>&nbsp;Job</span>`, then the duration on the right */
function readJob(job: Element): RawJob {
	const link = job.querySelector<HTMLAnchorElement>(selectors.jobLink);
	const icon = link?.querySelector('svg');
	const clean = (text: string | undefined): string => text?.replaceAll(/\s+/g, ' ').trim() ?? '';

	const spans = [...link?.querySelectorAll(selectors.jobNameParts) ?? []].map(span => clean(span.textContent));
	// "A / B" is two spans around a "/" span. A plain job is a single span
	const parts = spans.filter(text => text !== '/' && text !== '');
	const name = parts.length > 0 ? parts.at(-1)! : clean(link?.innerText);
	// The link text elides the middle of a long path with "...", the tooltip keeps it. Matrix pages fetched later have no tooltip, and need the spans
	const describedBy = link?.getAttribute('aria-describedby');
	const tooltip = describedBy ? link?.ownerDocument.getElementById(describedBy)?.textContent : undefined;
	const workflow = workflowFromTooltip(tooltip, name) ?? (parts.length > 1 ? parts.slice(0, -1).join(' / ') : null);

	return {
		name,
		workflow,
		duration: clean(link?.querySelector(selectors.jobDuration)?.textContent) || null,
		href: link?.getAttribute('href') ?? null,
		icon: icon ? [...icon.classList].join(' ') : null,
		label: icon?.getAttribute('aria-label') ?? null,
	};
}

/**
 * A matrix GitHub has collapsed ("4 jobs completed") has no job elements, only a summary button.
 * An unstarted one ("Waiting for pending jobs") has neither, and stays a card with no jobs.
 */
function readCollapsedMatrix(card: Element): {summary: RawJob; key: string; url: string} | undefined {
	const button = card.querySelector<HTMLElement>(selectors.collapsedMatrix);
	const url = button?.dataset.updateUrl;
	if (!button || !url) {
		return undefined;
	}

	const icon = button.querySelector('svg');
	const text = button.textContent.replaceAll(/\s+/g, ' ').replace('Show all jobs', '').trim();
	return {
		key: `${url}|${text}`,
		url,
		summary: {
			name: text,
			href: null,
			icon: icon ? [...icon.classList].join(' ') : null,
			label: icon?.getAttribute('aria-label') ?? null,
			count: parseMatrixSummary(text),
		},
	};
}

/** The same HTML GitHub's own "Show all jobs" button swaps in, so every job reads the way it does in the graph */
async function expandMatrix(state: State, key: string, url: string): Promise<void> {
	if (state.requested.has(key)) {
		return;
	}

	state.requested.add(key);
	try {
		const response = await fetch(url, {headers: {'X-Requested-With': 'XMLHttpRequest'}});
		if (!response.ok) {
			return;
		}

		const page = new DOMParser().parseFromString(await response.text(), 'text/html');
		const jobs = [...page.querySelectorAll(selectors.job)].map(job => readJob(job));
		if (jobs.length > 0) {
			state.expanded.set(key, jobs);
			state.onExpanded();
		}
	} catch {
		// The summary box stays on screen, which is still correct, only less detailed
	}
}

function readModel(graph: Element, state: State): Model {
	const cards: RawCard[] = [...graph.querySelectorAll<HTMLElement>(selectors.card)].map(card => {
		let jobs = [...card.querySelectorAll(selectors.job)].map(job => readJob(job));
		if (jobs.length === 0) {
			const matrix = readCollapsedMatrix(card);
			if (matrix) {
				const fetched = state.expanded.get(matrix.key);
				jobs = fetched ?? [matrix.summary];
				if (!fetched) {
					void expandMatrix(state, matrix.key, matrix.url);
				}
			}
		}

		return {
			id: card.id,
			title: card.querySelector(selectors.cardTitle)?.textContent.trim() ?? null,
			jobs,
		};
	});

	const edges = new Set<string>();
	for (const line of graph.querySelectorAll<SVGPathElement>(selectors.connector)) {
		edges.add(`${line.dataset.from!}\t${line.dataset.to!}`);
	}

	return buildModel(cards, [...edges].map(edge => edge.split('\t') as [string, string]));
}

function ensureStyles(): void {
	if (document.querySelector('#cig-style')) {
		return;
	}

	const style = document.createElement('style');
	style.id = 'cig-style';
	style.textContent = `
		/* GitHub's own graph stays in the DOM (it is the data source and keeps streaming updates), just not on screen */
		.${mountClass} + ${selectors.graph}, ${selectors.graph}.cig-replaced { display: none !important; }
		.${mountClass} { border: 1px solid var(--borderColor-default, #d1d9e0); border-radius: 6px; background: var(--bgColor-inset, #f6f8fa); margin-bottom: 16px; overflow: hidden; }
		.cig-viewport { position: relative; height: 70vh; min-height: 320px; overflow: hidden; cursor: grab; outline: none; user-select: none; touch-action: none; }
		.cig-viewport.cig-dragging { cursor: grabbing; }
		/* A drag crosses dozens of cards. Each one would light up and dim the other 200, repainting the whole stage on every frame, for a highlight nobody is looking at */
		.cig-viewport.cig-dragging .cig-stage { pointer-events: none; }
		.cig-stage { position: absolute; top: 0; left: 0; transform-origin: 0 0; will-change: transform; }
		.cig-controls { position: absolute; top: 8px; right: 8px; display: flex; gap: 4px; }
		.cig-label { position: absolute; top: 8px; left: 8px; padding: 3px 8px; border-radius: 6px; font-size: 12px; color: var(--fgColor-muted, #59636e); background: var(--bgColor-default, #fff); border: 1px solid var(--borderColor-default, #d1d9e0); pointer-events: none; }
		.cig-button { min-width: 28px; height: 28px; padding: 0 8px; border: 1px solid var(--borderColor-default, #d1d9e0); border-radius: 6px; background: var(--bgColor-default, #fff); color: var(--fgColor-default, #1f2328); font: inherit; font-size: 13px; cursor: pointer; }
		.cig-button:hover { background: var(--bgColor-muted, #f6f8fa); }
		/* Hovering a card: everything else fades, the card and its neighbours stay, and the overlay draws their lines on top */
		.cig-graph.cig-dim .cig-card { opacity: 0.3; }
		.cig-graph.cig-dim .cig-card.cig-lit { opacity: 1; }
		.cig-graph.cig-dim .cig-edges { opacity: 0.12; }
		.cig-card { transition: opacity 80ms; }
		.cig-card.cig-lit > rect:first-child { stroke: var(--fgColor-accent, #0969da); stroke-width: 2; }
		.cig-link { cursor: pointer; }
		.cig-link:hover .cig-row-bg { stroke: var(--borderColor-emphasis, #818b98); stroke-width: 1; }
		.cig-link:hover text:not([font-size="13"]) { text-decoration: underline; }
		/* "only" sits in the row's free space, just left of the count. The row is position: relative, so this is anchored to it */
		.${onlyClass} { position: absolute; right: 52px; top: 50%; translate: 0 -50%; padding: 0 4px; border: 0; background: none; font: inherit; font-size: 12px; color: var(--fgColor-accent, #0969da); opacity: 0.55; cursor: pointer; }
		[role="menuitemradio"]:hover .${onlyClass}, .${onlyClass}:hover, .${onlyClass}:focus-visible { opacity: 1; }
		.${onlyClass}:hover { text-decoration: underline; }
		/* Sidebar: \`li:has(> a)\` is a job, \`li:has(> button + ul)\` is a group of jobs. A group stays while any job in it matches */
		.${filteringClass} nav[aria-label="Workflow run"] li:has(> a[data-test-selector="job-link"]:not(.${matchClass})),
		.${filteringClass} nav[aria-label="Workflow run"] li:has(> button + ul):not(:has(.${matchClass})) { display: none; }
	`;
	document.head.append(style);
}

/** Is this menu item one of the status rows of the sidebar's own filter menu (and not some other menu on the page)? */
function isStatusMenuItem(item: HTMLElement): boolean {
	const button = document.querySelector(selectors.filterButton);
	const menu = item.closest(selectors.menu);
	return Boolean(button && menu) && menu!.getAttribute('aria-labelledby') === button!.getAttribute('aria-labelledby');
}

function menuItemLabel(item: HTMLElement): string {
	return item.querySelector(selectors.menuItemLabel)?.textContent.trim() ?? '';
}

/** Adds the "only" link to a menu row. React rebuilds the rows whenever the menu opens, so this runs often and must be idempotent */
function ensureOnlyLink(item: HTMLElement): void {
	if (item.querySelector(`.${onlyClass}`)) {
		return;
	}

	const label = menuItemLabel(item);
	// "All" is the select-all row, not a status
	if (label === '' || label === 'All') {
		return;
	}

	const only = document.createElement('button');
	only.type = 'button';
	only.className = onlyClass;
	only.textContent = 'only';
	only.title = `Show only ${label.toLowerCase()} jobs`;
	only.setAttribute('aria-label', `Show only ${label.toLowerCase()} jobs`);
	// Out of the menu's arrow-key order; a keyboard user still has the row itself
	only.tabIndex = -1;
	item.append(only);
}

/** Everything in GitHub's sidebar that has to agree with `state.excluded`. Cheap, and safe to run on every DOM change */
function syncSidebar(state: State): void {
	for (const link of document.querySelectorAll<HTMLElement>(selectors.sidebarJobLink)) {
		const icon = link.querySelector(selectors.sidebarIcon);
		const status = statusOfJob(icon ? [...icon.classList].join(' ') : null, icon?.getAttribute('aria-label') ?? null);
		link.classList.toggle(matchClass, isVisible(status, state.excluded));
	}

	document.documentElement.classList.toggle(filteringClass, state.excluded.size > 0);

	// React re-renders the heading, so write it again whenever it differs
	const heading = document.querySelector(selectors.heading);
	const title = getTitle(state.excluded);
	if (heading && heading.textContent !== title) {
		heading.textContent = title;
	}

	for (const item of document.querySelectorAll<HTMLElement>(selectors.menuItem)) {
		if (!isStatusMenuItem(item)) {
			continue;
		}

		const label = menuItemLabel(item);
		item.setAttribute('aria-checked', String(label === 'All' ? state.excluded.size === 0 : !state.excluded.has(label)));
		ensureOnlyLink(item);
	}
}

function draw(state: State, refit: boolean): void {
	const graph = document.querySelector<HTMLElement>(selectors.graph);
	if (!graph) {
		return;
	}

	graph.classList.add('cig-replaced');
	let mount = document.querySelector<HTMLElement>(`.${mountClass}`);
	if (!mount) {
		mount = document.createElement('div');
		mount.className = mountClass;
		mount.append(state.viewer.element);
		graph.before(mount);
	}

	const model = readModel(graph, state);
	const shown = reduceEdges(filterModel(model, state.excluded));

	// Layout takes long on big runs, so skip it when GitHub's DOM changed but nothing we draw did
	const signature = JSON.stringify(shown);
	if (signature !== state.lastSignature || refit) {
		state.lastSignature = signature;
		state.measures ??= createCanvasMeasures(getComputedStyle(mount).fontFamily);
		const layout = layoutModel(shown, state.measures);
		// The viewer is already in the page here, so "fit" measures a real box
		state.viewer.setContent(renderLayout(layout), layout, refit || state.firstDraw);
		state.firstDraw = false;
	}

	state.viewer.setLabel(`${countJobs(shown)} of ${countJobs(model)} jobs shown`);
}

function applyPick(state: State, item: HTMLElement, only: boolean): void {
	const label = menuItemLabel(item);
	state.excluded = only ? onlyExcluded(state.excluded, label) : toggleExcluded(state.excluded, label);
	syncSidebar(state);
	// A different set of cards is a different picture: start from "fit" again
	draw(state, true);
}

/**
 * GitHub closes its filter menu and picks a single status on every click.
 * Catching the event first lets the menu stay open and behave like checkboxes.
 * A click on a row's "only" link is also inside the row, so it has to be told apart from a plain toggle.
 */
function handlePick(state: State, event: Event): void {
	const target = event.target instanceof Element ? event.target : null;
	const item = target?.closest<HTMLElement>(selectors.menuItem);
	if (!item || !isStatusMenuItem(item)) {
		return;
	}

	event.preventDefault();
	event.stopImmediatePropagation();

	if (event.type === 'click' || event.type === 'keydown') {
		applyPick(state, item, Boolean(target!.closest(`.${onlyClass}`)));
	}
}

function debounce(callback: () => void, delay: number): () => void {
	let timer: ReturnType<typeof setTimeout> | undefined;
	return () => {
		clearTimeout(timer);
		timer = setTimeout(callback, delay);
	};
}

function main(): void {
	ensureStyles();
	const drawSoon = debounce(() => {
		if (document.querySelector(selectors.graph)) {
			draw(state, false);
		}
	}, 300);

	const state: State = {
		excluded: defaultExcluded,
		lastSignature: undefined,
		viewer: createViewer(),
		firstDraw: true,
		measures: undefined,
		expanded: new Map(),
		requested: new Set(),
		onExpanded() {
			drawSoon();
		},
	};

	// Runs before React's own handlers, which are on the root
	document.addEventListener('click', event => {
		handlePick(state, event);
	}, true);
	for (const type of ['keydown', 'keypress', 'keyup'] as const) {
		document.addEventListener(type, event => {
			if (event.key === 'Enter' || event.key === ' ') {
				handlePick(state, event);
			}
		}, true);
	}

	const syncSoon = debounce(() => {
		syncSidebar(state);
	}, 0);
	// Jobs stream in and change status while a run is going, React renders the sidebar late,
	// and the menu is rebuilt on every open, so there is no single element to wait for
	new MutationObserver(records => {
		// Ignore our own mount, otherwise drawing retriggers drawing
		if (records.every(record => (record.target as Element).closest?.(`.${mountClass}`))) {
			return;
		}

		syncSoon();
		drawSoon();
	}).observe(document.body, {childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'd']});

	syncSidebar(state);
	drawSoon();
}

main();
