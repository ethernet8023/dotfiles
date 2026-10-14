import type {Layout, PlacedCard, PlacedEdge, PlacedJob} from './layout.js';
import {
	cardContentTop,
	cardPadding,
	detailFontSize,
	detailLineHeight,
	glyphWidth,
	nameFontSize,
	nameLineHeight,
} from './layout.js';
import {type Status, worstStatus} from './model.js';

const svgNamespace = 'http://www.w3.org/2000/svg';

const statusColor: Record<Status, string> = {
	Successful: 'var(--fgColor-success, #1a7f37)',
	Failed: 'var(--fgColor-danger, #d1242f)',
	Cancelled: 'var(--fgColor-muted, #59636e)',
	Skipped: 'var(--fgColor-muted, #59636e)',
	'In progress': 'var(--fgColor-attention, #9a6700)',
	Queued: 'var(--fgColor-attention, #9a6700)',
	'Action required': 'var(--fgColor-attention, #9a6700)',
	'Timed out': 'var(--fgColor-danger, #d1242f)',
	Waiting: 'var(--fgColor-muted, #59636e)',
	Unknown: 'var(--fgColor-muted, #59636e)',
};

const statusGlyph: Record<Status, string> = {
	Successful: '✓',
	Failed: '✕',
	Cancelled: '⊘',
	Skipped: '⤼',
	'In progress': '●',
	Queued: '◔',
	'Action required': '!',
	'Timed out': '⏱',
	Waiting: '○',
	Unknown: '?',
};

/**
 * Card and cell backgrounds. GitHub's `-muted` tokens are already tuned for light and dark themes, so these follow the theme.
 * Statuses with nothing to say (skipped, not started, unknown) keep the plain card colour: tinting them would just be noise.
 */
const statusTint: Record<Status, {fill: string; stroke: string} | undefined> = {
	Successful: {fill: 'var(--bgColor-success-muted, #dafbe1)', stroke: 'var(--borderColor-success-muted, #4ac26b66)'},
	Failed: {fill: 'var(--bgColor-danger-muted, #ffebe9)', stroke: 'var(--borderColor-danger-muted, #ff818266)'},
	'Timed out': {fill: 'var(--bgColor-danger-muted, #ffebe9)', stroke: 'var(--borderColor-danger-muted, #ff818266)'},
	'In progress': {fill: 'var(--bgColor-attention-muted, #fff8c5)', stroke: 'var(--borderColor-attention-muted, #d4a72c66)'},
	Queued: {fill: 'var(--bgColor-attention-muted, #fff8c5)', stroke: 'var(--borderColor-attention-muted, #d4a72c66)'},
	'Action required': {fill: 'var(--bgColor-severe-muted, #fff1e5)', stroke: 'var(--borderColor-severe-muted, #db6d2866)'},
	Cancelled: {fill: 'var(--bgColor-neutral-muted, #818b981f)', stroke: 'var(--borderColor-muted, #d1d9e0b3)'},
	Skipped: undefined,
	Waiting: undefined,
	Unknown: undefined,
};

const plainFill = 'var(--bgColor-default, #fff)';
const plainStroke = 'var(--borderColor-default, #d1d9e0)';

const muted = 'var(--fgColor-muted, #59636e)';
const accent = 'var(--fgColor-accent, #0969da)';

function svg<K extends keyof SVGElementTagNameMap>(
	tag: K,
	attributes: Record<string, string | number> = {},
	...children: Array<Node | string>
): SVGElementTagNameMap[K] {
	const element = document.createElementNS(svgNamespace, tag);
	for (const [name, value] of Object.entries(attributes)) {
		element.setAttribute(name, String(value));
	}

	element.append(...children);
	return element;
}

/** Smooth horizontal curve through the points dagre routed; dagre already avoids crossing cards */
function edgePath({points}: PlacedEdge): string {
	const [first, ...rest] = points;
	if (!first) {
		return '';
	}

	let path = `M ${first.x} ${first.y}`;
	let previous = first;
	for (const point of rest) {
		const middle = (previous.x + point.x) / 2;
		path += ` C ${middle} ${previous.y}, ${middle} ${point.y}, ${point.x} ${point.y}`;
		previous = point;
	}

	return path;
}

function tooltipOf({job}: PlacedJob): string {
	const name = job.workflow ? `${job.workflow} / ${job.name}` : job.name;
	return [name, job.status, job.duration].filter(Boolean).join(' · ');
}

function renderJob(placed: PlacedJob, inGrid: boolean): SVGGElement {
	const {job, nameLines, detail, width, height} = placed;
	// In a grid the card's colour is only the worst job's, so each cell says its own; a lone job already has the whole card
	const cellFill = inGrid ? statusTint[job.status]?.fill : undefined;
	const textLeft = glyphWidth;
	const row = svg('g', {class: 'cig-row', transform: `translate(${placed.x} ${placed.y})`});

	const body: SVGElement[] = [
		// Fills the whole cell, so the link is clickable anywhere on it and not only on the letters
		svg('rect', {class: 'cig-row-bg', width, height, rx: 4, fill: cellFill ?? 'transparent', 'data-status': job.status}),
		svg('text', {x: 4, y: 16, 'font-size': 13, fill: statusColor[job.status]}, statusGlyph[job.status]),
	];

	const name = svg('text', {x: textLeft, y: 16, 'font-size': nameFontSize, fill: 'var(--fgColor-default, #1f2328)'});
	for (const [index, line] of nameLines.entries()) {
		name.append(svg('tspan', {x: textLeft, dy: index === 0 ? 0 : nameLineHeight}, line));
	}

	body.push(name);

	if (detail) {
		const top = 4 + nameLines.length * nameLineHeight;
		for (const [index, line] of detail.split('\n').entries()) {
			body.push(svg('text', {x: textLeft, y: top + detailFontSize + index * detailLineHeight, 'font-size': detailFontSize, fill: muted}, line));
		}
	}

	body.push(svg('title', {}, tooltipOf(placed)));

	if (job.href) {
		// A new tab, so the graph keeps its place and zoom
		row.append(svg('a', {href: job.href, target: '_blank', rel: 'noopener noreferrer', class: 'cig-link'}, ...body));
	} else {
		row.append(...body);
	}

	return row;
}

function renderCard({card, x, y, width, height, titleLines, noteLines, jobs}: PlacedCard): SVGGElement {
	const group = svg('g', {class: 'cig-card', transform: `translate(${x} ${y})`, 'data-card-id': card.id});
	// One job: the whole card is its colour. Several: each cell is tinted, so the card stays plain behind them,
	// otherwise a failed cell on a failed card is the same pink as the card and disappears. The border still says the worst status
	const worst = worstStatus(jobs.map(placed => placed.job.status));
	const tint = worst ? statusTint[worst] : undefined;
	const isGrid = jobs.length > 1;
	group.append(svg('rect', {
		width,
		height,
		rx: 6,
		fill: isGrid ? plainFill : tint?.fill ?? plainFill,
		stroke: tint?.stroke ?? plainStroke,
		'stroke-width': isGrid && tint ? 2 : 1,
		'data-status': worst ?? '',
	}));

	let top = cardPadding;
	if (titleLines.length > 0) {
		const title = svg('text', {x: cardPadding, y: top + 11, 'font-size': 11, 'font-weight': 600, fill: muted});
		for (const [index, line] of titleLines.entries()) {
			title.append(svg('tspan', {x: cardPadding, dy: index === 0 ? 0 : 14}, line));
		}

		group.append(title);
		top += titleLines.length * 14 + 4;
	}

	if (noteLines.length > 0) {
		// The part every job in the grid shares, said once instead of in every cell
		const note = svg('text', {class: 'cig-note', x: cardPadding, y: top + 10, 'font-size': 11, fill: muted});
		for (const [index, line] of noteLines.entries()) {
			note.append(svg('tspan', {x: cardPadding, dy: index === 0 ? 0 : 13}, line));
		}

		group.append(note);
	}

	if (jobs.length === 0) {
		group.append(svg('text', {x: cardPadding, y: cardContentTop(titleLines, noteLines) + 14, 'font-size': 12, fill: muted}, 'Waiting for pending jobs'));
	}

	for (const job of jobs) {
		group.append(renderJob(job, jobs.length > 1));
	}

	return group;
}

export function renderLayout(layout: Layout): SVGSVGElement {
	const root = svg('svg', {
		class: 'cig-graph',
		width: layout.width,
		height: layout.height,
		viewBox: `0 0 ${layout.width} ${layout.height}`,
		role: 'img',
		'aria-label': 'Workflow job graph',
	});

	const edgeGroup = svg('g', {class: 'cig-edges', fill: 'none', stroke: 'var(--borderColor-emphasis, #818b98)', 'stroke-width': 1.2, opacity: 0.7});
	const edgesOf = new Map<string, PlacedEdge[]>();
	const neighbors = new Map<string, Set<string>>();
	for (const edge of layout.edges) {
		edgeGroup.append(svg('path', {d: edgePath(edge), 'data-from': edge.from, 'data-to': edge.to}));
		for (const [id, other] of [[edge.from, edge.to], [edge.to, edge.from]] as const) {
			edgesOf.set(id, [...edgesOf.get(id) ?? [], edge]);
			neighbors.set(id, (neighbors.get(id) ?? new Set()).add(other));
		}
	}

	root.append(edgeGroup);

	// Lit lines are copies drawn on top of everything, so they are never hidden behind a card or another line
	const overlay = svg('g', {class: 'cig-overlay', fill: 'none', stroke: accent, 'stroke-width': 2.5, 'pointer-events': 'none'});
	const cardElements = new Map<string, SVGGElement>();
	let lit: SVGGElement[] = [];

	const light = (id: string): void => {
		root.classList.add('cig-dim');
		const ids = [id, ...neighbors.get(id) ?? []];
		lit = ids.flatMap(other => cardElements.get(other) ?? []);
		for (const element of lit) {
			element.classList.add('cig-lit');
		}

		overlay.replaceChildren(...(edgesOf.get(id) ?? []).map(edge => svg('path', {d: edgePath(edge)})));
	};

	const unlight = (): void => {
		root.classList.remove('cig-dim');
		for (const element of lit) {
			element.classList.remove('cig-lit');
		}

		lit = [];
		overlay.replaceChildren();
	};

	for (const placed of layout.cards) {
		const element = renderCard(placed);
		cardElements.set(placed.card.id, element);
		element.addEventListener('pointerenter', () => {
			light(placed.card.id);
		});
		element.addEventListener('pointerleave', unlight);
		root.append(element);
	}

	root.append(overlay);
	return root;
}
