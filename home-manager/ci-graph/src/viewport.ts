import {fit, panBy, toCss, type Size, type Transform, wheelFactor, zoomAt} from './transform.js';

const buttonStep = 1.25;

export type Viewer = {
	element: HTMLElement;
	/** Swap the drawn content. Keeps the user's pan/zoom unless `refit` is set */
	setContent(content: SVGSVGElement, size: Size, refit: boolean): void;
	setLabel(text: string): void;
};

function button(label: string, title: string, onClick: () => void): HTMLButtonElement {
	const element = document.createElement('button');
	element.type = 'button';
	element.className = 'cig-button';
	element.textContent = label;
	element.title = title;
	element.addEventListener('click', onClick);
	return element;
}

export function createViewer(): Viewer {
	const element = document.createElement('div');
	element.className = 'cig-viewport';
	element.tabIndex = 0;

	const stage = document.createElement('div');
	stage.className = 'cig-stage';
	element.append(stage);

	let transform: Transform = {x: 0, y: 0, scale: 1};
	let contentSize: Size = {width: 0, height: 0};
	/** Once the user pans or zooms, stop re-fitting behind their back */
	let touched = false;

	const viewportSize = (): Size => ({width: element.clientWidth, height: element.clientHeight});
	const centerOfViewport = (): {x: number; y: number} => ({x: element.clientWidth / 2, y: element.clientHeight / 2});

	function render(next: Transform): void {
		transform = next;
		stage.style.transform = toCss(transform);
	}

	function apply(next: Transform): void {
		touched = true;
		render(next);
	}

	const refit = (): void => {
		touched = false;
		render(fit(contentSize, viewportSize()));
	};

	// GitHub's page is still laying out when the first fit runs (sidebar, column width), so fit again as the box settles
	new ResizeObserver(() => {
		if (!touched && element.clientWidth > 0) {
			refit();
		}
	}).observe(element);

	const controls = document.createElement('div');
	controls.className = 'cig-controls';
	controls.append(
		button('+', 'Zoom in', () => {
			apply(zoomAt(transform, centerOfViewport(), buttonStep));
		}),
		button('−', 'Zoom out', () => {
			apply(zoomAt(transform, centerOfViewport(), 1 / buttonStep));
		}),
		button('Fit', 'Fit to screen (0)', refit),
	);
	element.append(controls);

	const label = document.createElement('div');
	label.className = 'cig-label';
	element.append(label);

	// Plain wheel zooms too: the graph is a canvas, not a page, and there is nothing to scroll inside it.
	// The page can still be scrolled with the cursor outside the graph.
	element.addEventListener('wheel', event => {
		event.preventDefault();
		const rect = element.getBoundingClientRect();
		const anchor = {x: event.clientX - rect.left, y: event.clientY - rect.top};
		apply(zoomAt(transform, anchor, wheelFactor(event.deltaY, event.deltaMode)));
	}, {passive: false});

	let drag: {x: number; y: number; pointerId: number} | undefined;
	element.addEventListener('pointerdown', event => {
		// Let clicks on job links and the buttons through
		if (event.button !== 0 || (event.target as Element).closest('a, button')) {
			return;
		}

		drag = {x: event.clientX, y: event.clientY, pointerId: event.pointerId};
		element.setPointerCapture(event.pointerId);
		element.classList.add('cig-dragging');
	});
	element.addEventListener('pointermove', event => {
		if (drag?.pointerId !== event.pointerId) {
			return;
		}

		apply(panBy(transform, event.clientX - drag.x, event.clientY - drag.y));
		drag = {...drag, x: event.clientX, y: event.clientY};
	});
	const endDrag = (event: PointerEvent): void => {
		if (drag?.pointerId === event.pointerId) {
			drag = undefined;
			element.classList.remove('cig-dragging');
		}
	};

	element.addEventListener('pointerup', endDrag);
	element.addEventListener('pointercancel', endDrag);

	element.addEventListener('keydown', event => {
		if (event.key === '0') {
			refit();
		} else if (event.key === '+' || event.key === '=') {
			apply(zoomAt(transform, centerOfViewport(), buttonStep));
		} else if (event.key === '-') {
			apply(zoomAt(transform, centerOfViewport(), 1 / buttonStep));
		}
	});

	return {
		element,
		setLabel(text) {
			// Same text is still a DOM write, and the page-wide observer would see it
			if (label.textContent !== text) {
				label.textContent = text;
			}
		},
		setContent(content, size, shouldRefit) {
			stage.replaceChildren(content);
			stage.style.width = `${size.width}px`;
			stage.style.height = `${size.height}px`;
			contentSize = size;
			if (shouldRefit) {
				refit();
			}
		},
	};
}
