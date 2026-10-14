export type Transform = {
	/** Screen px of the content's top-left corner */
	x: number;
	y: number;
	/** Screen px per content px */
	scale: number;
};

export type Size = {width: number; height: number};

export const minScale = 0.02;
export const maxScale = 3;

export function clampScale(scale: number): number {
	return Math.min(maxScale, Math.max(minScale, scale));
}

/**
 * Largest scale at which all the content is visible, centered.
 * Never zooms in past 1: a three-card graph should not be blown up to the size of the screen.
 */
export function fit(content: Size, viewport: Size, padding = 16): Transform {
	if (content.width <= 0 || content.height <= 0) {
		return {x: 0, y: 0, scale: 1};
	}

	const scale = clampScale(Math.min(
		1,
		(viewport.width - padding * 2) / content.width,
		(viewport.height - padding * 2) / content.height,
	));

	return {
		scale,
		x: (viewport.width - content.width * scale) / 2,
		y: (viewport.height - content.height * scale) / 2,
	};
}

/** Zooms so the content point under `anchor` (viewport px) stays under it */
export function zoomAt(transform: Transform, anchor: {x: number; y: number}, factor: number): Transform {
	const scale = clampScale(transform.scale * factor);
	const ratio = scale / transform.scale;
	return {
		scale,
		x: anchor.x - (anchor.x - transform.x) * ratio,
		y: anchor.y - (anchor.y - transform.y) * ratio,
	};
}

export function panBy(transform: Transform, dx: number, dy: number): Transform {
	return {...transform, x: transform.x + dx, y: transform.y + dy};
}

/** Wheel `deltaY` to a zoom factor; exponential, so zooming in then out by the same amount returns to the start */
export function wheelFactor(deltaY: number, deltaMode: number): number {
	// Line mode (Firefox mouse wheels) reports ~3 lines per notch, pixel mode ~100px per notch
	const pixels = deltaMode === 1 ? deltaY * 33 : deltaY;
	return Math.exp(-pixels * 0.002);
}

export function toCss({x, y, scale}: Transform): string {
	return `translate(${x}px, ${y}px) scale(${scale})`;
}
