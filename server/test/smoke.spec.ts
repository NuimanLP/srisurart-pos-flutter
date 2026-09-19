import { describe, it, expect } from 'vitest';

describe('Lab 03 Deliberate Test Break', () => {
    it('should fail deliberately for Task 6', () => {
        // จงใจเทียบ 1 ต้องเท่ากับ 2 เพื่อให้เกิดข้อผิดพลาดในการเทสต์
        expect(1).toBe(1);
    });
});
