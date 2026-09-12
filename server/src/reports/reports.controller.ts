import {
  BadRequestException,
  Controller,
  Get,
  Query,
  UseGuards,
} from '@nestjs/common';
import { TenantGuard } from '../common/guards/tenant.guard.js';
import {
  MAX_LIMIT,
  Paginated,
  pageParams,
  positiveInt,
} from '../common/paginated.js';
import { reportDateRange } from './reports.dto.js';
import {
  type CategorySales,
  type LowStockProduct,
  type ProductSales,
  type ReportSummary,
  ReportsService,
  type StockValue,
} from './reports.service.js';

@Controller('reports')
@UseGuards(TenantGuard)
export class ReportsController {
  constructor(private readonly reports: ReportsService) {}

  @Get('summary')
  summary(
    @Query('from') from?: string,
    @Query('to') to?: string,
  ): Promise<ReportSummary> {
    return this.reports.summary(reportDateRange(from, to));
  }

  @Get('top-products')
  topProducts(
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('limit') limit?: string,
  ): Promise<ProductSales[]> {
    return this.reports.topProducts(
      reportDateRange(from, to),
      Math.min(positiveInt(limit, 10, 'limit'), MAX_LIMIT),
    );
  }

  @Get('by-category')
  byCategory(
    @Query('from') from?: string,
    @Query('to') to?: string,
  ): Promise<CategorySales[]> {
    return this.reports.byCategory(reportDateRange(from, to));
  }

  @Get('stock-value')
  stockValue(): Promise<StockValue> {
    return this.reports.stockValue();
  }

  @Get('low-stock')
  async lowStock(
    @Query('page') page?: string,
    @Query('limit') limit?: string,
  ): Promise<Paginated<LowStockProduct>> {
    const parsed = pageParams(page, limit);
    const result = await this.reports.lowStock(parsed.page, parsed.limit);
    return new Paginated(result.items, { total: result.total, ...parsed });
  }

  @Get('product-sales')
  productSales(
    @Query('productId') productId: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
  ): Promise<ProductSales> {
    if (!productId) {
      throw new BadRequestException('productId is required');
    }
    return this.reports.productSales(productId, reportDateRange(from, to));
  }
}
