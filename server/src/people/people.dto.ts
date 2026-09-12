import { BadRequestException } from '@nestjs/common';
import { fromSatang, toSatang } from '../common/money.js';

export interface CustomerCreate {
  name: string;
  nameTH: string;
  phone: string | null;
  address: string | null;
}

export interface CustomerPatch {
  name?: string;
  nameTH?: string;
  phone?: string | null;
  address?: string | null;
}

export interface MechanicCreate {
  name: string;
  nameTH: string | null;
  nickname: string | null;
  shopName: string | null;
  phone: string | null;
  note: string | null;
  creditLimit: string;
}

export interface MechanicPatch {
  name?: string;
  nameTH?: string | null;
  nickname?: string | null;
  shopName?: string | null;
  phone?: string | null;
  note?: string | null;
  creditLimit?: string;
}

export function parseCustomerCreate(body: unknown): CustomerCreate {
  const value = asObject(body);
  return {
    name: requiredString(value.name, 'name'),
    nameTH: requiredString(value.nameTH, 'nameTH'),
    phone: optionalString(value.phone, 'phone'),
    address: optionalString(value.address, 'address'),
  };
}

export function parseCustomerPatch(body: unknown): CustomerPatch {
  const value = asObject(body);
  return compact({
    name: present(value, 'name')
      ? requiredString(value.name, 'name')
      : undefined,
    nameTH: present(value, 'nameTH')
      ? requiredString(value.nameTH, 'nameTH')
      : undefined,
    phone: present(value, 'phone')
      ? optionalString(value.phone, 'phone')
      : undefined,
    address: present(value, 'address')
      ? optionalString(value.address, 'address')
      : undefined,
  });
}

export function parseMechanicCreate(body: unknown): MechanicCreate {
  const value = asObject(body);
  return {
    name: requiredString(value.name, 'name'),
    nameTH: optionalString(value.nameTH, 'nameTH'),
    nickname: optionalString(value.nickname, 'nickname'),
    shopName: optionalString(value.shopName, 'shopName'),
    phone: optionalString(value.phone, 'phone'),
    note: optionalString(value.note, 'note'),
    creditLimit: nonNegativeMoney(value.creditLimit ?? '0.00', 'creditLimit'),
  };
}

export function parseMechanicPatch(body: unknown): MechanicPatch {
  const value = asObject(body);
  return compact({
    name: present(value, 'name')
      ? requiredString(value.name, 'name')
      : undefined,
    nameTH: present(value, 'nameTH')
      ? optionalString(value.nameTH, 'nameTH')
      : undefined,
    nickname: present(value, 'nickname')
      ? optionalString(value.nickname, 'nickname')
      : undefined,
    shopName: present(value, 'shopName')
      ? optionalString(value.shopName, 'shopName')
      : undefined,
    phone: present(value, 'phone')
      ? optionalString(value.phone, 'phone')
      : undefined,
    note: present(value, 'note')
      ? optionalString(value.note, 'note')
      : undefined,
    creditLimit: present(value, 'creditLimit')
      ? nonNegativeMoney(value.creditLimit, 'creditLimit')
      : undefined,
  });
}

export function isoDate(
  raw: string | undefined,
  field: string,
): string | undefined {
  if (raw === undefined || raw === '') return undefined;
  if (Number.isNaN(Date.parse(raw))) {
    throw new BadRequestException(`${field} must be an ISO-8601 timestamp`);
  }
  return raw;
}

function asObject(body: unknown): Record<string, unknown> {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    throw new BadRequestException('body must be an object');
  }
  return body as Record<string, unknown>;
}

function present(value: Record<string, unknown>, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(value, key);
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new BadRequestException(`${field} is required`);
  }
  return value;
}

function optionalString(value: unknown, field: string): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string') {
    throw new BadRequestException(`${field} must be a string`);
  }
  return value;
}

function nonNegativeMoney(value: unknown, field: string): string {
  const amount = toSatang(value, field);
  if (amount < 0) {
    throw new BadRequestException(`${field} must not be negative`);
  }
  return fromSatang(amount);
}

function compact<T extends object>(value: T): T {
  return Object.fromEntries(
    Object.entries(value).filter(([, field]) => field !== undefined),
  ) as T;
}
