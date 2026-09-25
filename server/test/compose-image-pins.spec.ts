import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// #401 — every external `image:` in these compose files must be pinned to a digest
// (`name:tag@sha256:<digest>`), same policy as the base images in Dockerfile. Our own
// images (built locally, or GHCR images pinned by CI in deploy/compose/vm.override.yml)
// are exempt — they are not what this ticket is about, and vm.override.yml pins by
// ${IMAGE_TAG}, not a literal digest in the file.
const OWN_IMAGE_PREFIXES = ['srisurart-pos/', 'ghcr.io/nuimanlp/'];

function extractImageLines(path: string): string[] {
  const text = readFileSync(path, 'utf8');
  return text
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.startsWith('image:'));
}

describe('compose files pin every external image to a digest (#401)', () => {
  it.each([
    ['server/docker-compose.yml', join(__dirname, '..', 'docker-compose.yml')],
    ['deploy/compose/monitoring.yml', join(__dirname, '..', '..', 'deploy', 'compose', 'monitoring.yml')],
  ])('%s', (_label, path) => {
    const imageLines = extractImageLines(path);
    expect(imageLines.length).toBeGreaterThan(0);

    for (const line of imageLines) {
      const image = line.replace(/^image:\s*/, '');
      const isOwnImage = OWN_IMAGE_PREFIXES.some((prefix) => image.startsWith(prefix));
      if (isOwnImage) continue;

      expect(image, `${image} must be pinned as name:tag@sha256:<digest>`).toMatch(/@sha256:[0-9a-f]{64}$/);
    }
  });
});
