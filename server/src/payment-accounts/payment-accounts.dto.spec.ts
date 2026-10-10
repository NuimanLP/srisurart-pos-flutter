import { describe, expect, it } from 'vitest';
import { testId } from '../../test/support/test-ids.js';
import { parsePaymentAccountCreate, parsePaymentAccountPatch } from './payment-accounts.dto.js';
import { decodeQrImage, isPromptPayId, MAX_IMAGE_BYTES, normaliseNickname } from './payment-accounts.rules.js';

const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13]);
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 16, 0x4a, 0x46]);
const b64 = (b: Buffer) => b.toString('base64');

describe('payment account rules', () => {
  it('promptpayId: phone (10 digits from 0), 13-digit id, 15-digit e-wallet — digits only', () => {
    for (const ok of ['0812345678', '1234567890123', '123456789012345']) expect(isPromptPayId(ok), ok).toBe(true);
    for (const bad of ['812345678', '1812345678', '081-234-5678', '12345678901234', '1234567890123456', '', 812345678]) {
      expect(isPromptPayId(bad), String(bad)).toBe(false);
    }
  });

  it('nickname: 1–40 characters after trim', () => {
    expect(normaliseNickname('  บัญชีร้าน  ')).toBe('บัญชีร้าน');
    expect(normaliseNickname('x'.repeat(40))).toBe('x'.repeat(40));
    expect(normaliseNickname('x'.repeat(41))).toBeNull();
    expect(normaliseNickname('   ')).toBeNull();
    expect(normaliseNickname(7)).toBeNull();
  });

  it('image: magic bytes must match the mime', () => {
    expect(decodeQrImage(b64(PNG), 'image/png')).toMatchObject({ mime: 'image/png' });
    expect(decodeQrImage(b64(JPEG), 'image/jpeg')).toMatchObject({ mime: 'image/jpeg' });
    expect(decodeQrImage(b64(JPEG), 'image/png')).toEqual({ problem: 'image bytes are not a image/png' });
    expect(decodeQrImage(b64(PNG), 'image/jpeg')).toEqual({ problem: 'image bytes are not a image/jpeg' });
    expect(decodeQrImage(b64(PNG), 'image/gif')).toMatchObject({ problem: expect.stringMatching(/imageMime/) });
  });

  it('image: plain base64 only, no data: prefix, not empty', () => {
    expect(decodeQrImage(`data:image/png;base64,${b64(PNG)}`, 'image/png')).toMatchObject({
      problem: expect.stringMatching(/plain base64/),
    });
    expect(decodeQrImage('', 'image/png')).toMatchObject({ problem: expect.stringMatching(/plain base64/) });
    expect(decodeQrImage('abc', 'image/png')).toMatchObject({ problem: expect.stringMatching(/plain base64/) });
  });

  it('image: at most 300 KB decoded — the limit itself passes, one byte more does not', () => {
    const atLimit = Buffer.concat([PNG, Buffer.alloc(MAX_IMAGE_BYTES - PNG.length)]);
    expect(decodeQrImage(b64(atLimit), 'image/png')).toMatchObject({ mime: 'image/png' });
    const over = Buffer.concat([PNG, Buffer.alloc(MAX_IMAGE_BYTES - PNG.length + 1)]);
    expect(decodeQrImage(b64(over), 'image/png')).toEqual({ problem: `image must be at most ${MAX_IMAGE_BYTES} bytes` });
  });
});

describe('parsePaymentAccountCreate', () => {
  const promptpay = {
    id: testId('pa1'),
    nickname: ' บัญชีร้าน ',
    bankCode: 'KBANK',
    kind: 'promptpay',
    promptpayId: '0812345678',
    imageBase64: null,
    imageMime: null,
    isDefault: true,
  };
  const image = { id: testId('pa2'), nickname: 'รูป QR', bankCode: 'SCB', kind: 'image', imageBase64: b64(PNG), imageMime: 'image/png' };

  it('reads a PromptPay account (the contract wire shape, nulls included)', () => {
    expect(parsePaymentAccountCreate(promptpay)).toEqual({
      id: testId('pa1'),
      nickname: 'บัญชีร้าน',
      bankCode: 'KBANK',
      kind: 'promptpay',
      promptpayId: '0812345678',
      image: null,
      isDefault: true,
      sortOrder: 0,
    });
  });

  it('reads an image account, decoded', () => {
    const parsed = parsePaymentAccountCreate(image);
    expect(parsed).toMatchObject({ kind: 'image', promptpayId: null, isDefault: false, sortOrder: 0 });
    expect(parsed.image?.bytes.equals(PNG)).toBe(true);
    expect(parsed.image?.mime).toBe('image/png');
  });

  it.each([
    ['a missing id', { id: undefined }, /id is required/],
    ['a non-UUID id', { id: 'pa1' }, /id must be a lowercase UUID/],
    ['an empty nickname', { nickname: '  ' }, /nickname/],
    ['an unknown bank', { bankCode: 'XBANK' }, /bankCode/],
    ['an unknown kind', { kind: 'cash' }, /kind/],
    ['a bad PromptPay id', { promptpayId: '12345' }, /promptpayId/],
    ['an image on a PromptPay account', { imageBase64: b64(PNG), imageMime: 'image/png' }, /only for kind 'image'/],
    ['a non-boolean isDefault', { isDefault: 'true' }, /isDefault/],
    ['a negative sortOrder', { sortOrder: -1 }, /sortOrder/],
    ['a fractional sortOrder', { sortOrder: 1.5 }, /sortOrder/],
  ])('refuses %s', (_label, extra, message) => {
    expect(() => parsePaymentAccountCreate({ ...promptpay, ...extra })).toThrow(message);
  });

  it('refuses a promptpayId on an image account, and an image account without its image', () => {
    expect(() => parsePaymentAccountCreate({ ...image, promptpayId: '0812345678' })).toThrow(/only for kind 'promptpay'/);
    expect(() => parsePaymentAccountCreate({ ...image, imageBase64: undefined })).toThrow(/plain base64/);
    expect(() => parsePaymentAccountCreate({ ...image, imageMime: undefined })).toThrow(/imageMime/);
  });

  it('refuses a body that is not an object', () => {
    expect(() => parsePaymentAccountCreate(null)).toThrow(/JSON object/);
    expect(() => parsePaymentAccountCreate([])).toThrow(/JSON object/);
  });
});

describe('parsePaymentAccountPatch', () => {
  it('reads only what is sent', () => {
    expect(parsePaymentAccountPatch({})).toEqual({});
    expect(parsePaymentAccountPatch({ isDefault: true })).toEqual({ isDefault: true });
    expect(parsePaymentAccountPatch({ nickname: ' ใหม่ ', sortOrder: 3 })).toEqual({ nickname: 'ใหม่', sortOrder: 3 });
  });

  it('treats null on the kind-specific fields as not sent, and ignores id/updatedAt', () => {
    expect(
      parsePaymentAccountPatch({
        id: testId('pa1'),
        updatedAt: '2026-10-10T00:00:00.000Z',
        promptpayId: null,
        imageBase64: null,
        imageMime: null,
        bankCode: 'BBL',
      }),
    ).toEqual({ bankCode: 'BBL' });
  });

  it('reads kind (checked against the row by the service) and an image', () => {
    const patch = parsePaymentAccountPatch({ kind: 'image', imageBase64: b64(JPEG), imageMime: 'image/jpeg' });
    expect(patch.kind).toBe('image');
    expect(patch.image?.mime).toBe('image/jpeg');
  });

  it('refuses bad values instead of ignoring them', () => {
    expect(() => parsePaymentAccountPatch({ kind: 'cash' })).toThrow(/kind/);
    expect(() => parsePaymentAccountPatch({ nickname: '' })).toThrow(/nickname/);
    expect(() => parsePaymentAccountPatch({ promptpayId: '0812' })).toThrow(/promptpayId/);
    expect(() => parsePaymentAccountPatch({ imageBase64: b64(PNG) })).toThrow(/imageMime/);
    expect(() => parsePaymentAccountPatch({ isDefault: 1 })).toThrow(/isDefault/);
  });
});
