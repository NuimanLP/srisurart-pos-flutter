import { BadRequestException } from '@nestjs/common';
import {
  parseCustomerPatch,
  parseMechanicCreate,
  parseMechanicPatch,
} from './people.dto.js';

/**
 * mob04 2026-10-03: every "+ เพิ่มช่าง" save was a 400. The add dialog has only a
 * Thai-name field, so `ApiMechanicsRepository.addMechanic` always sends
 * `name: ''`. This body is the one the Dart test
 * (`api_repositories_write_test.dart` › "the add dialog never sets name")
 * pins for the name-only case.
 */
const DIALOG_NAME_ONLY = {
  name: '',
  nameTH: 'ทดสอบ-ลบได้',
  nickname: '',
  shopName: '',
  phone: '',
  note: '',
  creditLimit: '0.00',
};

describe('people DTOs — name falls back to nameTH', () => {
  it('accepts the add-mechanic dialog body and takes name from nameTH', () => {
    expect(parseMechanicCreate(DIALOG_NAME_ONLY)).toMatchObject({
      name: 'ทดสอบ-ลบได้',
      nameTH: 'ทดสอบ-ลบได้',
      creditLimit: '0.00',
    });
  });

  it('keeps a real name over nameTH', () => {
    expect(
      parseMechanicCreate({ name: 'Ek', nameTH: 'เอก' }).name,
    ).toBe('Ek');
  });

  it('still refuses no usable name, and a non-string name', () => {
    expect(() => parseMechanicCreate({ name: ' ', nameTH: '' })).toThrow(
      BadRequestException,
    );
    expect(() => parseMechanicCreate({})).toThrow(BadRequestException);
    expect(() => parseMechanicCreate({ name: 5, nameTH: 'เอก' })).toThrow(
      BadRequestException,
    );
    expect(() => parseMechanicPatch({ name: '' })).toThrow(BadRequestException);
  });

  it('customer patch: blank EN takes the Thai name, blank Thai takes EN', () => {
    expect(parseCustomerPatch({ name: '', nameTH: 'ลูกค้า' })).toMatchObject({
      name: 'ลูกค้า',
      nameTH: 'ลูกค้า',
    });
    expect(parseCustomerPatch({ name: 'Somchai', nameTH: '' })).toMatchObject({
      name: 'Somchai',
      nameTH: 'Somchai',
    });
    expect(() => parseCustomerPatch({ name: '', nameTH: '' })).toThrow(
      BadRequestException,
    );
  });
});
