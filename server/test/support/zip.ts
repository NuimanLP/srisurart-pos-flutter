import yauzl from 'yauzl';
import yazl from 'yazl';

/** Every entry of a ZIP (name → bytes). Test helper: a backup ZIP is small here. */
export function unzipEntries(zipBytes: Buffer): Promise<Map<string, Buffer>> {
  return new Promise((resolve, reject) => {
    yauzl.fromBuffer(zipBytes, { lazyEntries: true }, (err, zip) => {
      if (err || !zip) return reject(err ?? new Error('no zip'));
      const out = new Map<string, Buffer>();
      zip.on('entry', (entry: yauzl.Entry) => {
        zip.openReadStream(entry, (e, stream) => {
          if (e || !stream) return reject(e ?? new Error('no stream'));
          const chunks: Buffer[] = [];
          stream.on('data', (c: Buffer) => chunks.push(c));
          stream.on('error', reject);
          stream.on('end', () => {
            out.set(entry.fileName, Buffer.concat(chunks));
            zip.readEntry();
          });
        });
      });
      zip.on('end', () => resolve(out));
      zip.on('error', reject);
      zip.readEntry();
    });
  });
}

/** `data.json` of a backup ZIP, parsed. */
export async function backupDataJson(zipBytes: Buffer): Promise<Record<string, any>> {
  const entries = await unzipEntries(zipBytes);
  const data = entries.get('data.json');
  if (!data) throw new Error('backup ZIP has no data.json');
  return JSON.parse(data.toString('utf8'));
}

/**
 * A ZIP whose entry names yazl itself refuses to write (`../x`, `/abs`): written under a
 * same-length placeholder, then the name bytes are swapped in the local and central headers.
 */
export async function zipWithRawNames(entries: Array<[string, Buffer | string]>): Promise<Buffer> {
  const placeholders = entries.map(([name], i) => `q${String(i).padStart(name.length - 1, 'q')}`.slice(0, name.length));
  const zip = await zipOf(entries.map(([, bytes], i) => [placeholders[i], bytes]));
  let out = zip;
  entries.forEach(([name], i) => {
    const from = Buffer.from(placeholders[i], 'utf8');
    const to = Buffer.from(name, 'utf8');
    if (from.length !== to.length) throw new Error('raw names must be ASCII');
    let at = out.indexOf(from);
    while (at !== -1) {
      to.copy(out, at);
      at = out.indexOf(from, at + to.length);
    }
  });
  return out;
}

/** Builds a ZIP from `name → bytes`. */
export function zipOf(entries: Array<[string, Buffer | string]>): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const zip = new yazl.ZipFile();
    for (const [name, bytes] of entries) {
      zip.addBuffer(typeof bytes === 'string' ? Buffer.from(bytes, 'utf8') : bytes, name);
    }
    zip.end();
    const chunks: Buffer[] = [];
    zip.outputStream.on('data', (c: Buffer) => chunks.push(c));
    zip.outputStream.on('error', reject);
    zip.outputStream.on('end', () => resolve(Buffer.concat(chunks)));
  });
}
