import {build} from 'esbuild';
import {cp, mkdir, rm} from 'node:fs/promises';

await rm('dist', {recursive: true, force: true});
await mkdir('dist', {recursive: true});

await build({
	entryPoints: {content: 'src/content.ts'},
	outdir: 'dist',
	bundle: true,
	format: 'iife',
	target: ['firefox133', 'chrome140'],
	minify: false,
	sourcemap: false,
	logLevel: 'info',
});

await cp('manifest.json', 'dist/manifest.json');
