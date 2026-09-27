/**
 * Offline common-password blocklist for a password a shop owner chooses (#443 PR3).
 *
 * Owner decision 2026-09-27 (#443, Q4): SecLists' top-10k common passwords, filtered to the
 * entries that are at least `MIN_PASSWORD_LENGTH` (12) characters long — a shorter entry can
 * never pass the length floor, so keeping it would only cost memory — plus shop-specific
 * words (below, `SHOP_WORDS`). Bundled in the image: no network lookup, ever (FortiGate).
 *
 * Source:   https://github.com/danielmiessler/SecLists
 * File:     Passwords/Common-Credentials/10k-most-common.txt
 * Commit:   913b327317496d062bcc7cace524aaad8a693be2 (the last commit touching that file,
 *           fetched 2026-09-27; sha256 of the file at that commit:
 *           68782d6a4a19a4768d5f15dd66bd534e7a33055cc755411e33f16d18c50fdcce)
 * Filter:   `awk 'length($0) >= 12'` — keeps 10 of the 10,000 entries, verbatim.
 * License:  MIT —
 *
 *   MIT License
 *
 *   Copyright (c) 2018 Daniel Miessler
 *
 *   Permission is hereby granted, free of charge, to any person obtaining a copy
 *   of this software and associated documentation files (the "Software"), to deal
 *   in the Software without restriction, including without limitation the rights
 *   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 *   copies of the Software, and to permit persons to whom the Software is
 *   furnished to do so, subject to the following conditions:
 *
 *   The above copyright notice and this permission notice shall be included in all
 *   copies or substantial portions of the Software.
 *
 *   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 *   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 *   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 *   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 *   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 *   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 *   SOFTWARE.
 *
 * 🔴 Only 10 entries survive the filter: the top-10k list is almost entirely short
 * passwords. That is what the owner's rule produces; a larger source (e.g. a 100k/1M list
 * filtered the same way) is an owner decision, not something to swap in silently.
 *
 * A TypeScript module rather than a `.txt` asset: it is loaded once with the module, needs
 * no `nest-cli.json` asset rule, and cannot go missing from `dist/` in the image.
 */
export const COMMON_PASSWORDS: ReadonlySet<string> = new Set([
  'masterbating',
  'unbelievable',
  'businessbabe',
  'contortionist',
  'masterbaiting',
  'masturbation',
  'pornographic',
  'scandinavian',
  'films+pic+galeries',
  'motherfucker',
]);

/**
 * Context-specific words (NIST SP 800-63B §5.1.1.2: "the name of the service"): the shop's own
 * name in the spellings people actually type. Unlike the list above these are matched as a
 * *substring* of the password with separators removed — every one of them is shorter than 12,
 * so an exact match could never fire; `srisurart2569!!` is the password this is for.
 */
export const SHOP_WORDS: readonly string[] = ['srisurart', 'srisurat', 'ศรีสุรัต'];
