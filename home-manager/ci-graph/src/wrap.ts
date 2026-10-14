/** Measures a string's rendered width in px. Injected so wrapping is testable without a browser */
export type Measure = (text: string) => number;

/**
 * Greedy word wrap into at most `maxLines` lines no wider than `maxWidth`.
 * Breaks after spaces, and also after `/`, `-`, `_` and `(` so job names like `build-darwin-arm64-release` can break.
 * A single unbreakable piece wider than the line is cut by characters, so nothing ever overflows the card.
 * If the text still does not fit in `maxLines`, the last line ends in an ellipsis.
 */
export function wrapText(text: string, maxWidth: number, maxLines: number, measure: Measure): string[] {
	const clean = text.replaceAll(/\s+/g, ' ').trim();
	if (clean === '' || maxLines < 1) {
		return [];
	}

	if (measure(clean) <= maxWidth) {
		return [clean];
	}

	// Pieces keep their trailing separator, so joining them back reproduces the text
	const pieces = clean.match(/[^\s/_(-]+[\s/_(-]*|[\s/_(-]+/g) ?? [clean];
	const lines: string[] = [];
	let current = '';

	const push = (line: string): void => {
		lines.push(line.trimEnd());
	};

	for (let piece of pieces) {
		while (measure(piece.trimEnd()) > maxWidth) {
			if (current !== '') {
				push(current);
				current = '';
				continue;
			}

			// Cut an over-long piece by characters. Always take at least one, or a too-narrow card loops forever
			let cut = piece.length - 1;
			while (cut > 1 && measure(piece.slice(0, cut)) > maxWidth) {
				cut--;
			}

			cut = Math.max(1, cut);
			push(piece.slice(0, cut));
			piece = piece.slice(cut);
			if (piece === '') {
				break;
			}
		}

		if (piece === '') {
			continue;
		}

		if (current !== '' && measure((current + piece).trimEnd()) > maxWidth) {
			push(current);
			current = piece;
		} else {
			current += piece;
		}
	}

	if (current.trim() !== '') {
		push(current);
	}

	if (lines.length <= maxLines) {
		return lines;
	}

	// Too long even when wrapped: keep the first lines, and end the last one with an ellipsis that fits
	const kept = lines.slice(0, maxLines);
	let last = kept[maxLines - 1]!;
	while (last.length > 1 && measure(last + '…') > maxWidth) {
		last = last.slice(0, -1);
	}

	kept[maxLines - 1] = last.trimEnd() + '…';
	return kept;
}
