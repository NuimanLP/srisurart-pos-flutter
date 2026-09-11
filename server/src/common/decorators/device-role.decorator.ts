import { SetMetadata } from '@nestjs/common';

export const REQUIRE_DEVICE_ROLE_KEY = 'requireDeviceRole';
export const RequireDeviceRole = (role: 'pos' | 'backoffice') => SetMetadata(REQUIRE_DEVICE_ROLE_KEY, role);
