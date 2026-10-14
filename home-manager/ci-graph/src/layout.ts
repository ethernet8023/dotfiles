import dagre from '@dagrejs/dagre';

import {compactCard} from './compact.js';
import type {Card, Job, Model} from './model.js';
import {type Measure, wrapText} from './wrap.js';

export type Size = {width: number; height: number};

/** One job's cell inside a card, already wrapped and measured */
export type PlacedJob = {
	job: Job;
	/** Offset from the top-left of the card */
	x: number;
	y: number;
	width: number;
	height: number;
	nameLines: string[];
	/** Small grey line under the name: duration, status, and the workflow when the card header does not already say it */
	detail: string | undefined;
};

export type PlacedCard = {
	card: Card;
	x: number;
	y: number;
	titleLines: string[];
	/** What every job in the card has in common, said once under the title */
	noteLines: string[];
	jobs: PlacedJob[];
} & Size;

export type PlacedEdge = {from: string; to: string; points: Array<{x: number; y: number}>};

export type Layout = {
	cards: PlacedCard[];
	edges: PlacedEdge[];
} & Size;

export const cardPadding = 8;
/** A card with one job keeps the full-width row; a card with several jobs is a grid of narrower cells */
export const singleWidth = 280;
export const cellWidth = 190;
export const cellGap = 6;
/** Most columns a grid gets, so a 25-job card is a 5x5 block and not one long strip */
export const maxColumns = 5;
/** Where the text starts inside a cell: the status glyph sits in front of it */
export const glyphWidth = 20;
export const nameFontSize = 12;
export const detailFontSize = 11;
export const nameLineHeight = 16;
export const detailLineHeight = 14;
const titleLineHeight = 14;
const noteLineHeight = 13;
const rowGap = 4;
const maxNameLines = 4;
const maxDetailLines = 2;
const maxTitleLines = 2;
const maxNoteLines = 2;
const emptyCardRows = 1;

export type Measures = {
	name: Measure;
	detail: Measure;
	title: Measure;
};

/** How many columns a card of `count` jobs gets: one for a lone job, then as square as the cap allows */
export function columnsFor(count: number): number {
	if (count <= 1) {
		return 1;
	}

	return Math.min(maxColumns, Math.max(2, Math.ceil(Math.sqrt(count))));
}

export function cardWidthFor(count: number): number {
	const columns = columnsFor(count);
	return columns === 1 ? singleWidth : cardPadding * 2 + columns * cellWidth + (columns - 1) * cellGap;
}

/** Where the first job starts, below the card's (possibly wrapped) title and its note */
export function cardContentTop(titleLines: string[], noteLines: string[] = []): number {
	const title = titleLines.length > 0 ? titleLines.length * titleLineHeight + 4 : 0;
	const note = noteLines.length > 0 ? noteLines.length * noteLineHeight + 4 : 0;
	return cardPadding + title + note;
}

function detailOf(job: Job, workflow: string | undefined): string | undefined {
	const parts = [
		workflow,
		job.count > 1 ? `${job.count} jobs` : undefined,
		job.duration,
		// The glyph is a colour and a shape; say the word too, so a card is readable without decoding the icon
		job.status === 'Successful' || job.status === 'Waiting' ? undefined : job.status,
	].filter((part): part is string => Boolean(part));
	return parts.length > 0 ? parts.join(' · ') : undefined;
}

function placeJob(job: Job, label: string, workflow: string | undefined, width: number, measures: Measures): Omit<PlacedJob, 'x' | 'y'> {
	const textWidth = width - glyphWidth - cardPadding;
	const nameLines = wrapText(label, textWidth, maxNameLines, measures.name);
	const detail = detailOf(job, workflow);
	const detailLines = detail ? wrapText(detail, textWidth, maxDetailLines, measures.detail) : [];
	const height = nameLines.length * nameLineHeight + detailLines.length * detailLineHeight + 8;
	return {job, width, height, nameLines: nameLines.length > 0 ? nameLines : [''], detail: detailLines.length > 0 ? detailLines.join('\n') : undefined};
}

export function measureCard(card: Card, measures: Measures): {size: Size; titleLines: string[]; noteLines: string[]; jobs: PlacedJob[]} {
	const columns = columnsFor(card.jobs.length);
	const width = cardWidthFor(card.jobs.length);
	const cell = columns === 1 ? width - cardPadding * 2 : cellWidth;

	const titleLines = card.title ? wrapText(card.title, width - cardPadding * 2, maxTitleLines, measures.title) : [];
	const compact = compactCard(card);
	const noteLines = compact.note ? wrapText(compact.note, width - cardPadding * 2, maxNoteLines, measures.title) : [];

	const cells = card.jobs.map((job, index) => placeJob(job, compact.labels[index]!, compact.workflows[index], cell, measures));

	// Cells in a row share the row's height, so the grid stays aligned
	const top = cardContentTop(titleLines, noteLines);
	const jobs: PlacedJob[] = [];
	let y = top;
	for (let start = 0; start < cells.length; start += columns) {
		const rowCells = cells.slice(start, start + columns);
		const rowHeight = Math.max(...rowCells.map(c => c.height));
		for (const [column, placedCell] of rowCells.entries()) {
			jobs.push({...placedCell, height: rowHeight, x: cardPadding + column * (cellWidth + cellGap), y});
		}

		y += rowHeight + rowGap;
	}

	// A card with no jobs is a matrix that has not expanded yet: it still needs room for its one-line placeholder
	const bottom = jobs.length > 0 ? y - rowGap : top + emptyCardRows * 20;
	return {size: {width, height: bottom + cardPadding}, titleLines, noteLines, jobs};
}

export function layoutModel(model: Model, measures: Measures): Layout {
	const graph = new dagre.graphlib.Graph({multigraph: false});
	graph.setGraph({rankdir: 'LR', ranksep: 60, nodesep: 14, marginx: 16, marginy: 16, ranker: 'network-simplex'});
	graph.setDefaultEdgeLabel(() => ({}));

	const measured = new Map<string, ReturnType<typeof measureCard>>();
	for (const card of model.cards) {
		const result = measureCard(card, measures);
		measured.set(card.id, result);
		graph.setNode(card.id, result.size);
	}

	for (const [from, to] of model.edges) {
		graph.setEdge(from, to);
	}

	dagre.layout(graph);

	const cards: PlacedCard[] = model.cards.map(card => {
		const node = graph.node(card.id)!;
		const {titleLines, noteLines, jobs} = measured.get(card.id)!;
		// Dagre positions are centers; SVG wants the top-left corner
		return {card, titleLines, noteLines, jobs, x: node.x - node.width / 2, y: node.y - node.height / 2, width: node.width, height: node.height};
	});

	const edges: PlacedEdge[] = model.edges.map(([from, to]) => {
		const source = graph.node(from)!;
		const target = graph.node(to)!;
		// Dagre clips the line where it crosses the node's bounding box, which can be the top or bottom edge.
		// Always leave from the right-middle and arrive at the left-middle so the flow reads left to right.
		const route = graph.edge(from, to)!.points.slice(1, -1);
		return {
			from,
			to,
			points: [
				{x: source.x + source.width / 2, y: source.y},
				...route,
				{x: target.x - target.width / 2, y: target.y},
			],
		};
	});

	const {width = 0, height = 0} = graph.graph();
	return {cards, edges, width, height};
}

/** A browser-backed measurer: canvas `measureText` with the page's own font, so wrapping matches what is drawn */
export function createCanvasMeasures(fontFamily: string): Measures {
	const context = document.createElement('canvas').getContext('2d')!;
	const make = (fontSize: number, weight: number): Measure => {
		context.font = `${weight} ${fontSize}px ${fontFamily}`;
		const font = context.font;
		return text => {
			context.font = font;
			return context.measureText(text).width;
		};
	};

	return {name: make(nameFontSize, 400), detail: make(detailFontSize, 400), title: make(11, 600)};
}
